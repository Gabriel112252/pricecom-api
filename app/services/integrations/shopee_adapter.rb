module Integrations
  # Shopee Open Platform API (v2).
  #
  # ⚠️ UNVERIFIED: open.shopee.com could not be fetched in this environment
  # (blocked), so — like TiktokAdapter and MercadoLivreAdapter — this is
  # built from training knowledge, not a confirmed current copy of the
  # docs. Structurally this platform is believed to closely mirror
  # TikTok Shop's API shape (signed requests via partner_key, an envelope
  # response with an `error`/`message` pair instead of HTTP status codes
  # for most failures, and a two-step item list → item detail fetch), so
  # this adapter follows that pattern. Treat this as a placeholder to
  # correct against the real docs (or a sandbox account) before it ever
  # runs in production.
  class ShopeeAdapter < BaseChannelAdapter
    BASE_URL = "https://partner.shopeemobile.com".freeze
    ITEM_LIST_PATH = "/api/v2/product/get_item_list".freeze
    ITEM_INFO_PATH = "/api/v2/product/get_item_base_info".freeze
    PAGE_SIZE = 50
    ITEM_INFO_BATCH_SIZE = 50

    AUTH_ERROR_KEYWORDS = %w[sign signature access_token token auth invalid_partner].freeze
    RATE_LIMIT_KEYWORDS = %w[rate frequency too many limit].freeze

    def authenticate
      get(ITEM_LIST_PATH, offset: 0, page_size: 1, item_status: "NORMAL")
      true
    end

    def fetch_products
      item_ids = fetch_all_item_ids
      item_ids.each_slice(ITEM_INFO_BATCH_SIZE).flat_map { |batch| fetch_item_info(batch) }
    end

    def fetch_stock(external_id)
      body = get(ITEM_INFO_PATH, item_id_list: external_id)
      item = body.dig("response", "item_list")&.first || {}
      item.dig("stock_info_v2", "summary_info", "total_available_stock")
    end

    def normalize_product(raw)
      {
        external_id:  raw["item_id"].to_s,
        external_sku: raw["item_sku"],
        name:         raw["item_name"],
        price:        to_decimal(raw.dig("price_info", 0, "current_price")),
        stock_qty:    to_decimal(raw.dig("stock_info_v2", "summary_info", "total_available_stock")),
        raw:          raw
      }
    end

    private

    def fetch_all_item_ids
      ids = []
      offset = 0

      loop do
        body = get(ITEM_LIST_PATH, offset: offset, page_size: PAGE_SIZE, item_status: "NORMAL")
        page_items = body.dig("response", "item") || []
        ids.concat(page_items.map { |i| i["item_id"] })

        has_next = body.dig("response", "has_next_page")
        offset += PAGE_SIZE
        break unless has_next && page_items.any?
      end

      ids
    end

    def fetch_item_info(ids)
      body = get(ITEM_INFO_PATH, item_id_list: ids.join(","))
      body.dig("response", "item_list") || []
    end

    def get(path, **params)
      response = connection(BASE_URL).get(path, signed_params(path, params))
      body = handle_response(response)
      raise_on_body_error(body)
      body
    end

    # Shopee returns HTTP 200 for most application-level errors too,
    # encoding the real outcome in the response body's `error` field
    # (blank string = success). Best-effort classification into our
    # shared error types, since we don't have the real error-code table.
    def raise_on_body_error(body)
      error_code = body["error"].to_s
      return if error_code.blank?

      message = body["message"].to_s
      downcased = "#{error_code} #{message}".downcase

      if AUTH_ERROR_KEYWORDS.any? { |k| downcased.include?(k) }
        raise AuthenticationError, "ShopeeAdapter: #{message} (#{error_code})"
      elsif RATE_LIMIT_KEYWORDS.any? { |k| downcased.include?(k) }
        raise RateLimitError, "ShopeeAdapter: #{message} (#{error_code})"
      else
        raise ApiError, "ShopeeAdapter: #{message} (#{error_code})"
      end
    end

    # HMAC-SHA256 over partner_id + api_path + timestamp (+ access_token +
    # shop_id once authenticated) keyed by partner_key — the general
    # pattern Shopee's Open Platform API is documented (elsewhere) to use.
    # Unverified — see class comment.
    def signed_params(path, extra_params)
      timestamp = Time.now.to_i
      base_string = "#{credentials[:partner_id]}#{path}#{timestamp}#{credentials[:access_token]}#{credentials[:shop_id]}"
      sign = OpenSSL::HMAC.hexdigest("SHA256", credentials[:partner_key].to_s, base_string)

      extra_params.merge(
        partner_id: credentials[:partner_id],
        timestamp: timestamp,
        access_token: credentials[:access_token],
        shop_id: credentials[:shop_id],
        sign: sign
      )
    end
  end
end
