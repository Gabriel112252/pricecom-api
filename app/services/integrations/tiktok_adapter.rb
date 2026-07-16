module Integrations
  # TikTok Shop Partner API (Product + Order modules).
  #
  # Verified against TikTok Shop Partner Center docs in July 2026:
  # - Auth/signature: API version 202309+ sends access tokens through
  #   `x-tts-access-token`, signs only query params excluding
  #   `sign`/`access_token`, and appends the JSON body for non-multipart
  #   requests.
  # - Product payload: Search Products 202309
  #   (partner.tiktokshop.com/docv2/page/search-products-202309) — each
  #   skus[] entry has `id`, `seller_sku`, `price.{currency,
  #   tax_exclusive_price, sale_price}` and `inventory[].{warehouse_id,
  #   quantity}`. There is no `sku_id` or `price.amount` field.
  # - Order payload: Get Order List 202309
  #   (partner.tiktokshop.com/docv2/page/get-order-list-202309) —
  #   pagination/sort go in the query string, time/status filters in the
  #   JSON body, shop_cipher required in the query.
  class TiktokAdapter < BaseChannelAdapter
    include TiktokRequestSigning

    BASE_URL = "https://open-api.tiktokglobalshop.com".freeze
    PRODUCT_SEARCH_PATH = "/product/202309/products/search".freeze
    INVENTORY_SEARCH_PATH = "/product/202309/inventory/search".freeze
    ORDER_SEARCH_PATH = "/order/202309/orders/search".freeze
    ORDER_DETAIL_PATH = "/order/202309/orders".freeze
    SHOP_SCOPED_PATHS = [
      PRODUCT_SEARCH_PATH,
      INVENTORY_SEARCH_PATH,
      ORDER_SEARCH_PATH,
      ORDER_DETAIL_PATH
    ].freeze
    ORDER_DETAIL_MAX_IDS = 50
    PAGE_SIZE = 100
    ORDERS_PAGE_SIZE = 50

    # code => 0 means success. Auth/permission failures show up as the
    # 105xxx code family (e.g. 105005 already observed in production when
    # the app lacks the scope for an endpoint); keyword matching stays as a
    # fallback for other auth-shaped messages.
    AUTH_ERROR_KEYWORDS = %w[sign signature access_token token auth].freeze
    PERMISSION_ERROR_KEYWORDS = ["permission", "scope", "not authorized", "unauthorized"].freeze
    AUTH_ERROR_CODES = (105_000..105_999).freeze
    RATE_LIMIT_KEYWORDS = %w[rate frequency too many limit].freeze

    def authenticate
      post(PRODUCT_SEARCH_PATH, {}, query_params: { page_size: 1 })
      true
    end

    def fetch_products
      skus = []
      page_token = nil

      loop do
        query_params = { page_size: PAGE_SIZE, page_token: page_token }.compact
        body = post(PRODUCT_SEARCH_PATH, {}, query_params: query_params)
        data = body["data"] || {}

        (data["products"] || []).each do |product|
          (product["skus"] || []).each do |sku|
            skus << sku.merge("_product_title" => product["title"] || product["product_name"])
          end
        end

        page_token = data["next_page_token"]
        break if page_token.blank?
      end

      skus
    end

    def fetch_stock(external_id)
      body = post(INVENTORY_SEARCH_PATH, { sku_ids: [ external_id.to_s ] })
      inventories = body.dig("data", "inventory") || []
      inventories.sum do |inventory|
        (inventory["skus"] || []).sum { |sku| sku["total_available_quantity"].to_i }
      end
    end

    # `seller_sku` is optional in TikTok Shop (sellers often leave it
    # blank, and the API then returns an empty string), so fall back to the
    # TikTok-generated SKU `id` — otherwise every SKU without a seller code
    # is dropped by ProductSyncService as "sem SKU externo".
    # `sale_price` (tax-inclusive) only exists for CN cross-border sellers;
    # `tax_exclusive_price` is the regular selling-price field.
    def normalize_product(raw)
      {
        external_id:  raw["id"].to_s,
        external_sku: raw["seller_sku"].presence || raw["id"].to_s,
        name:         raw["_product_title"],
        price:        to_decimal(raw.dig("price", "sale_price").presence || raw.dig("price", "tax_exclusive_price")),
        stock_qty:    to_decimal((raw["inventory"] || []).sum { |inv| inv["quantity"].to_i }),
        raw:          raw.except("_product_title")
      }
    end

    # One page of the Get Order List API. Time/status filters
    # (create_time_ge/lt, update_time_ge/lt, order_status) belong in the
    # JSON body; page_size/page_token/sort_* belong in the query string.
    # Returns the response's "data" hash: { "orders" => [...],
    # "next_page_token" => ..., "total_count" => ... }.
    def fetch_orders_page(filters: {}, page_token: nil, page_size: ORDERS_PAGE_SIZE, sort_field: "create_time")
      query_params = {
        page_size:  page_size,
        page_token: page_token.presence,
        sort_field: sort_field,
        sort_order: "ASC"
      }.compact

      body = post(ORDER_SEARCH_PATH, filters.compact, query_params: query_params)
      body["data"] || {}
    end

    # Get Order Detail 202309
    # (partner.tiktokshop.com/docv2/page/get-order-detail-202309): GET with
    # the order ids as a comma-separated `ids` query param, up to 50 per
    # call. Returns the "orders" array (same order shape as Get Order List,
    # plus detail-only fields).
    def fetch_order_details(order_ids)
      ids = Array(order_ids).map(&:to_s).reject(&:blank?)
      return [] if ids.empty?
      if ids.size > ORDER_DETAIL_MAX_IDS
        raise ArgumentError, "TiktokAdapter#fetch_order_details aceita no máximo #{ORDER_DETAIL_MAX_IDS} ids por chamada"
      end

      body = get(ORDER_DETAIL_PATH, query_params: { ids: ids.join(",") })
      body.dig("data", "orders") || []
    end

    private

    def post(path, body, query_params: {})
      timestamp = Time.now.to_i
      encoded_body = encode_json_body(body)
      params = {
        app_key: credentials[:app_key],
        timestamp: timestamp
      }.merge(query_params.compact).merge(shop_scoped_query_params(path))
      params[:sign] = sign(path, params, encoded_body)

      response = connection(BASE_URL).post(path) do |req|
        req.params = params
        req.headers["x-tts-access-token"] = credentials[:access_token]
        req.headers["Content-Type"] = "application/json"
        req.body = encoded_body
      end

      parsed = handle_response(response)
      raise_on_body_error(parsed, path)
      parsed
    end

    # Same signing scheme as #post, but with no JSON body appended to the
    # signable string (GET endpoints sign only path + query params).
    def get(path, query_params: {})
      params = {
        app_key: credentials[:app_key],
        timestamp: Time.now.to_i
      }.merge(query_params.compact).merge(shop_scoped_query_params(path))
      params[:sign] = sign(path, params)

      response = connection(BASE_URL).get(path) do |req|
        req.params = params
        req.headers["x-tts-access-token"] = credentials[:access_token]
        req.headers["Content-Type"] = "application/json"
      end

      parsed = handle_response(response)
      raise_on_body_error(parsed, path)
      parsed
    end

    def shop_scoped_query_params(path)
      return {} unless SHOP_SCOPED_PATHS.include?(path)

      shop_cipher = credentials[:shop_cipher].presence
      if shop_cipher.blank?
        raise AuthenticationError,
          "TiktokAdapter: shop_cipher ausente; reautorize a integração TikTok Shop"
      end

      { shop_cipher: shop_cipher }
    end

    # TikTok Shop's API returns HTTP 200 for most application-level errors
    # too, encoding the real outcome in the response body's `code` field
    # (0 = success). The 105xxx family covers auth/permission failures
    # (invalid/expired token, missing scope — 105005 already seen in
    # production); scope errors get an explicit reauthorization hint so the
    # sync log tells the operator what to do.
    def raise_on_body_error(body, path = nil)
      code = body["code"]
      return if code.nil? || code.zero?

      message = body["message"].to_s
      downcased = message.downcase
      where = path ? " em #{path}" : ""

      if PERMISSION_ERROR_KEYWORDS.any? { |k| downcased.include?(k) }
        raise AuthenticationError,
          "TiktokAdapter: sem permissão/escopo#{where} (code #{code}: #{message}) — " \
          "ative o escopo correspondente no Partner Center (ex: Order Information) e reconecte o TikTok Shop"
      elsif AUTH_ERROR_CODES.cover?(code.to_i) || AUTH_ERROR_KEYWORDS.any? { |k| downcased.include?(k) }
        raise AuthenticationError, "TiktokAdapter: credenciais rejeitadas#{where} (code #{code}: #{message})"
      elsif RATE_LIMIT_KEYWORDS.any? { |k| downcased.include?(k) }
        raise RateLimitError, "TiktokAdapter: #{message} (code #{code})"
      else
        raise ApiError, "TiktokAdapter: #{message} (code #{code})"
      end
    end

    # HMAC-SHA256 over app_secret + path + sorted signed query params +
    # JSON body + app_secret. TikTok explicitly excludes `sign` and
    # `access_token`; for API version 202309+ the token is a header.
    def sign(path, params, encoded_body = nil)
      tiktok_sign(path, params, app_secret: credentials[:app_secret], encoded_body: encoded_body)
    end

    def encode_json_body(body)
      tiktok_json_body(body)
    end
  end
end
