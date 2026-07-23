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
  #   quantity}`. There is no `sku_id` or `price.amount` field. Each
  #   product (the sku's parent) also has its own `id` — the product_id
  #   #update_stock's write endpoint needs, see #fetch_products.
  # - Order payload: Get Order List 202309
  #   (partner.tiktokshop.com/docv2/page/get-order-list-202309) —
  #   pagination/sort go in the query string, time/status filters in the
  #   JSON body, shop_cipher required in the query.
  # - Write path (added 2026-07-21, confirmed from Partner Center, not
  #   inferred): Update Inventory 202309 (POST /product/202309/products/
  #   {product_id}/inventory/update) and Get Warehouse List 202309
  #   (GET /logistics/202309/warehouses) — see #update_stock/
  #   #resolve_warehouse_id.
  class TiktokAdapter < BaseChannelAdapter
    include TiktokRequestSigning

    BASE_URL = "https://open-api.tiktokglobalshop.com".freeze
    PRODUCT_SEARCH_PATH = "/product/202309/products/search".freeze
    PRODUCT_ACTIVATE_PATH = "/product/202309/products/activate".freeze
    PRODUCT_DEACTIVATE_PATH = "/product/202309/products/deactivate".freeze
    INVENTORY_SEARCH_PATH = "/product/202309/inventory/search".freeze
    WAREHOUSE_LIST_PATH = "/logistics/202309/warehouses".freeze
    ORDER_SEARCH_PATH = "/order/202309/orders/search".freeze
    ORDER_DETAIL_PATH = "/order/202309/orders".freeze
    FINANCIAL_STATEMENTS_PATH = "/finance/202309/statements".freeze
    STATEMENT_TRANSACTIONS_PATH = "/finance/202501/statements".freeze
    ORDER_STATEMENT_TRANSACTIONS_PATH = "/finance/202501/orders".freeze
    SHOP_SCOPED_PATHS = [
      PRODUCT_SEARCH_PATH,
      PRODUCT_ACTIVATE_PATH,
      PRODUCT_DEACTIVATE_PATH,
      INVENTORY_SEARCH_PATH,
      WAREHOUSE_LIST_PATH,
      ORDER_SEARCH_PATH,
      ORDER_DETAIL_PATH,
      FINANCIAL_STATEMENTS_PATH
    ].freeze
    # The inventory-update path has a dynamic {product_id} segment, so it
    # can't live in SHOP_SCOPED_PATHS (an exact-match list) — matched by
    # pattern instead, see #shop_scoped_query_params.
    INVENTORY_UPDATE_PATH_PATTERN = %r{\A/product/202309/products/[^/]+/inventory/update\z}.freeze
    ORDER_DETAIL_MAX_IDS = 50
    PAGE_SIZE = 100
    ORDERS_PAGE_SIZE = 50

    # code => 0 means success. Auth/permission failures show up as the
    # 105xxx code family (e.g. 105005 already observed in production when
    # the app lacks the scope for an endpoint); keyword matching stays as a
    # fallback for other auth-shaped messages.
    AUTH_ERROR_KEYWORDS = %w[sign signature access_token token auth].freeze
    PERMISSION_ERROR_KEYWORDS = %w[permission scope].freeze + [ "not authorized", "unauthorized" ].freeze
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
            skus << sku.merge(
              "_product_title" => product["title"] || product["product_name"],
              # Parent product id (distinct from the sku's own "id") — needed
              # by the inventory-update endpoint's {product_id} path param.
              # Free on this same call, like Shopify's inventory_item_id —
              # see #normalize_product/external_product_id.
              "_parent_product_id" => product["id"],
              # Product-level selling status (DRAFT/PENDING/FAILED/ACTIVATE/
              # SELLER_DEACTIVATED/PLATFORM_DEACTIVATED/FREEZE/DELETED) —
              # also free on this call, see #normalize_selling_status.
              "_product_status" => product["status"]
            )
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

    # Get Warehouse List 202309 (confirmed straight from Partner Center,
    # 2026-07-21 — not inferred): GET /logistics/202309/warehouses, no
    # extra query params beyond the usual app_key/timestamp/sign/
    # shop_cipher. Returns every warehouse on the seller's account
    # (sales, and potentially other kinds — see #resolve_warehouse_id for
    # why sales_warehouse-only is a documented assumption, not confirmed
    # from a real multi-warehouse Hidrabene payload).
    # → [{ id:, name:, effect_status:, type:, is_default: }, ...]
    def fetch_warehouses
      body = get(WAREHOUSE_LIST_PATH)
      (body.dig("data", "warehouses") || []).map { |raw| normalize_warehouse(raw) }
    end

    # Writes stock via POST /product/202309/products/{product_id}/
    # inventory/update — confirmed straight from Partner Center,
    # 2026-07-21, body `{ skus: [{ id:, inventory: [{ warehouse_id:,
    # quantity: }] }] }`.
    #
    # `product_id:` is required here rather than resolved internally —
    # same reason as ShopifyAdapter#update_stock's `inventory_item_id:`:
    # this adapter has no ActiveRecord access, so the caller resolves it
    # from the already-persisted ChannelProductListing#external_product_id
    # (see TiktokAdapter's class comment / #fetch_products) instead of this
    # method reaching into the database itself.
    #
    # backorder_quantity/handling_time are deliberately NOT sent — see the
    # 2026-07-21 investigation: every source found (TikTok's own docs on
    # the opt-in "Backorder" feature, and the laraditz/tiktok community
    # SDK's own working usage example) treats them as optional extras tied
    # to a seller-configured feature, not required for a plain stock
    # write. If that turns out to be wrong, TikTok's own code!=0 response
    # surfaces as a clean ApiError via #raise_on_body_error — not a silent
    # wrong write.
    def update_stock(external_id:, quantity:, product_id:)
      if product_id.blank?
        raise ArgumentError, "TiktokAdapter#update_stock: product_id ausente para sku=#{external_id}"
      end

      path = "/product/202309/products/#{product_id}/inventory/update"
      body = {
        skus: [
          { id: external_id.to_s, inventory: [ { warehouse_id: resolve_warehouse_id, quantity: quantity.to_i } ] }
        ]
      }
      post(path, body)
    end

    # `seller_sku` is optional in TikTok Shop (sellers often leave it
    # blank, and the API then returns an empty string), so fall back to the
    # TikTok-generated SKU `id` — otherwise every SKU without a seller code
    # is dropped by ProductSyncService as "sem SKU externo".
    # `sale_price` (tax-inclusive) only exists for CN cross-border sellers;
    # `tax_exclusive_price` is the regular selling-price field.
    def normalize_product(raw)
      {
        external_id:         raw["id"].to_s,
        external_sku:        raw["seller_sku"].presence || raw["id"].to_s,
        name:                raw["_product_title"],
        price:               to_decimal(raw.dig("price", "sale_price").presence || raw.dig("price", "tax_exclusive_price")),
        stock_qty:           to_decimal((raw["inventory"] || []).sum { |inv| inv["quantity"].to_i }),
        external_product_id: raw["_parent_product_id"]&.to_s,
        raw:                 raw.except("_product_title", "_parent_product_id", "_product_status")
      }.merge(normalize_selling_status(raw))
    end

    # ACTIVATE is the only status TikTok Shop actually sells through — every
    # other value in Search Products 202309's documented status list is
    # either pre-listing (DRAFT/PENDING/FAILED) or a platform/seller-side
    # takedown (SELLER_DEACTIVATED/PLATFORM_DEACTIVATED/FREEZE/DELETED).
    # None of those are ever offered as an editable target in the UI (see
    # the Fase 4 modal) — TikTok only exposes an activate/deactivate toggle,
    # never direct control over the platform-controlled ones.
    def normalize_selling_status(raw)
      status = raw["_product_status"]

      selling_status =
        case status
        when "ACTIVATE" then "selling"
        when "DRAFT", "PENDING", "FAILED" then "reviewing"
        when "SELLER_DEACTIVATED" then "inactive"
        when "PLATFORM_DEACTIVATED", "FREEZE" then "platform_blocked"
        when "DELETED" then "deleted"
        else "unknown"
        end

      {
        remote_status: status,
        remote_status_reason: nil,
        remote_status_metadata: {},
        selling_status: selling_status,
        selling_enabled: status == "ACTIVATE",
        replenishment_eligible: status == "ACTIVATE"
      }
    end

    # Fase 4 modal actions — activate/deactivate only (see
    # #normalize_selling_status's comment on why the platform-controlled
    # statuses are never offered as an editable target). Per TikTok Shop
    # Partner Center's Product module: POST /product/202309/products/
    # activate and .../deactivate, body { product_ids: [...] } — not
    # verified against a live store, same disclosure as the rest of this
    # adapter's write path (#update_stock).
    def activate_product(product_id:)
      post(PRODUCT_ACTIVATE_PATH, { product_ids: [ product_id.to_s ] })
    end

    def deactivate_product(product_id:)
      post(PRODUCT_DEACTIVATE_PATH, { product_ids: [ product_id.to_s ] })
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

    # Finance API 202501. Returns the complete statement-transactions
    # envelope; the financial sync service validates `code` and persists the
    # complete `data` payload for auditability.
    def fetch_order_statement_transactions(order_id)
      normalized_order_id = order_id.to_s.strip
      unless /\A\d+\z/.match?(normalized_order_id)
        raise ArgumentError, "TiktokAdapter#fetch_order_statement_transactions: order_id inválido"
      end

      shop_cipher = credentials[:shop_cipher].presence
      if shop_cipher.blank?
        raise AuthenticationError,
          "TiktokAdapter: shop_cipher ausente; reautorize a integração TikTok Shop"
      end

      path = "#{ORDER_STATEMENT_TRANSACTIONS_PATH}/#{normalized_order_id}/statement_transactions"
      get(path, query_params: { shop_cipher: shop_cipher })
    end

    # Get Statements 202309. The API only exposes data after 2023-07-01 and
    # uses an opaque cursor. Return the original statement objects unchanged;
    # the small PaginatedPayload wrapper only adds the raw response pages for
    # audit logs and tests.
    def fetch_financial_statements(
      statement_time_ge:,
      statement_time_lt:,
      page_size: PAGE_SIZE,
      page_token: nil,
      payment_status: nil
    )
      records = PaginatedPayload.new
      cursor = page_token

      loop do
        response = fetch_financial_statements_page(
          statement_time_ge: statement_time_ge,
          statement_time_lt: statement_time_lt,
          page_size: page_size,
          page_token: cursor,
          payment_status: payment_status
        )
        records.raw_pages << response
        data = response.fetch("data")
        statements = Array(data["statements"])
        records.concat(statements)
        cursor = data["next_page_token"]
        # Página vazia é fim de paginação de verdade, mesmo se a TikTok ainda
        # mandar um next_page_token não-nulo — nunca continuar batendo na API
        # por um cursor que não avança.
        break if statements.empty? || cursor.blank?
      end

      records
    end

    # One page is public as well so the statement backfill can checkpoint
    # between requests without restarting an entire date interval.
    def fetch_financial_statements_page(
      statement_time_ge:,
      statement_time_lt:,
      page_size: PAGE_SIZE,
      page_token: nil,
      payment_status: nil
    )
      query_params = {
        statement_time_ge: statement_time_ge,
        statement_time_lt: statement_time_lt,
        page_size: page_size,
        page_token: page_token.presence,
        payment_status: payment_status.presence,
        sort_field: "statement_time",
        sort_order: "ASC"
      }.compact

      response = get(FINANCIAL_STATEMENTS_PATH, query_params: query_params)
      validate_finance_page!(response, "statements")
      response
    end

    # Get Transactions by Statement 202501. Like statements, this returns
    # raw transaction objects and retains every response page.
    def fetch_statement_transactions(statement_id:, page_size: PAGE_SIZE, page_token: nil)
      normalized_statement_id = statement_id.to_s.strip
      if normalized_statement_id.blank?
        raise ArgumentError, "TiktokAdapter#fetch_statement_transactions: statement_id inválido"
      end

      records = PaginatedPayload.new
      cursor = page_token

      loop do
        response = fetch_statement_transactions_page(
          statement_id: normalized_statement_id,
          page_size: page_size,
          page_token: cursor
        )
        records.raw_pages << response
        data = response.fetch("data")
        transactions = Array(data["transactions"])
        records.concat(transactions)
        cursor = data["next_page_token"]
        # Um statement PAID sem nenhuma transação (ou o fim real da
        # paginação) vem como página vazia — parar aqui, mesmo com
        # next_page_token preenchido, evita voltar a bater na mesma página
        # pra sempre.
        break if transactions.empty? || cursor.blank?
      end

      records
    end

    def fetch_statement_transactions_page(statement_id:, page_size: PAGE_SIZE, page_token: nil)
      normalized_statement_id = statement_id.to_s.strip
      if normalized_statement_id.blank?
        raise ArgumentError, "TiktokAdapter#fetch_statement_transactions: statement_id inválido"
      end

      shop_cipher = credentials[:shop_cipher].presence
      if shop_cipher.blank?
        raise AuthenticationError,
          "TiktokAdapter: shop_cipher ausente; reautorize a integração TikTok Shop"
      end

      path = "#{STATEMENT_TRANSACTIONS_PATH}/#{normalized_statement_id}/statement_transactions"
      response = get(
        path,
        query_params: {
          page_size: page_size,
          page_token: page_token.presence,
          sort_field: "order_create_time",
          sort_order: "ASC",
          shop_cipher: shop_cipher
        }.compact
      )
      validate_finance_page!(response, "transactions")
      response
    end

    private

    class PaginatedPayload < Array
      attr_reader :raw_pages

      def initialize
        super
        @raw_pages = []
      end
    end

    def validate_finance_page!(response, collection_key)
      unless response.is_a?(Hash) && response["code"] == 0
        code = response.is_a?(Hash) ? response["code"] : nil
        message = response.is_a?(Hash) ? response["message"] : nil
        raise ApiError,
          "TiktokAdapter Finance API: code=#{code.inspect} message=#{message.inspect}"
      end

      data = response["data"]
      # TikTok pode omitir a chave ou devolver null pra esse array quando não
      # há registro nenhum (ex: statement PAID sem transação) — isso é uma
      # página vazia válida, não uma resposta malformada. Só um valor de tipo
      # errado (string, hash, etc.) é de fato inválido.
      unless data.is_a?(Hash) && (data[collection_key].nil? || data[collection_key].is_a?(Array))
        raise ApiError,
          "TiktokAdapter Finance API: data.#{collection_key} inválido"
      end
    end

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
      }.merge(query_params.compact).merge(shop_scoped_query_params(path)).merge(warehouse_compat_params(path))
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

    def normalize_warehouse(raw)
      {
        id: raw["id"],
        name: raw["name"],
        effect_status: raw["effect_status"],
        type: raw["type"],
        is_default: raw["is_default"]
      }
    end

    # Memoized per adapter instance, same reasoning as
    # ShopifyAdapter#resolve_location_id: a batch of writes in one run
    # pays for this lookup once, not once per SKU.
    #
    # type == "SALES_WAREHOUSE" is filtered in as a documented ASSUMPTION,
    # not a confirmed rule — the only real payload seen (Hidrabene, one
    # warehouse) is SALES_WAREHOUSE, and TikTok's own seller docs describe
    # other warehouse kinds (e.g. reverse-logistics/returns) existing on an
    # account, which would be wrong to write sellable stock into. If a
    # real multi-warehouse account turns out to have SALES_WAREHOUSE
    # entries this filter wrongly excludes, that's the thing to revisit.
    #
    # Never picks a warehouse arbitrarily: 0 candidates, or more than one
    # with no single is_default: true among them, raises ApiError with the
    # count and ids instead of guessing — same rule as Shopify's ambiguous
    # location check.
    def resolve_warehouse_id
      @warehouse_id ||= begin
        candidates = fetch_warehouses.select { |w| w[:effect_status] == "ENABLED" && w[:type] == "SALES_WAREHOUSE" }

        chosen = candidates.size == 1 ? candidates.first : single_default_among(candidates)

        unless chosen
          raise ApiError,
            "TiktokAdapter#update_stock: expected exactly one enabled sales warehouse (or exactly one marked " \
            "is_default among several), found #{candidates.size} candidate(s) (ids: #{candidates.map { |w| w[:id] }.join(', ')}) " \
            "— pick one explicitly instead of guessing"
        end

        chosen[:id]
      end
    end

    def single_default_among(candidates)
      return nil if candidates.size <= 1

      defaults = candidates.select { |w| w[:is_default] }
      defaults.size == 1 ? defaults.first : nil
    end

    def shop_scoped_query_params(path)
      return {} unless SHOP_SCOPED_PATHS.include?(path) || path.match?(INVENTORY_UPDATE_PATH_PATTERN)

      shop_cipher = credentials[:shop_cipher].presence
      if shop_cipher.blank?
        raise AuthenticationError,
          "TiktokAdapter: shop_cipher ausente; reautorize a integração TikTok Shop"
      end

      { shop_cipher: shop_cipher }
    end

    # Get Warehouse List 202309 still enforces the legacy-era signed
    # parameter set despite living under a /202309/ path — confirmed
    # 2026-07-22 by diffing a manually-built curl that succeeded against
    # the real API for this exact path against what this method was
    # sending. The working call had `access_token` as an explicit query
    # param (in addition to the x-tts-access-token header), `version`
    # (matching the path's own version), and `shop_id` present even as an
    # empty string — none of which this adapter was sending, which is why
    # every call here failed with a scope-shaped 401 even though
    # granted_scopes actually contains the right scope. `access_token` is
    # excluded from the signed base by #sign either way (see
    # TiktokRequestSigning#tiktok_sign), same as the working curl's own
    # sign; `version`/`shop_id` do get signed. Scoped to just this path —
    # product/order 202309 endpoints work fine today without any of this
    # and shouldn't get it added speculatively.
    def warehouse_compat_params(path)
      return {} unless path == WAREHOUSE_LIST_PATH

      { access_token: credentials[:access_token], version: "202309", shop_id: "" }
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
