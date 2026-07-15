module Integrations
  # TikTok Shop Partner API (Product module).
  #
  # ⚠️ PARTIALLY VERIFIED: the authentication/signature contract below was
  # checked against TikTok Shop Partner Center docs in July 2026: API
  # version 202309+ sends access tokens through `x-tts-access-token`, signs
  # only query params excluding `sign`/`access_token`, and appends the JSON
  # body for non-multipart requests. Product payload normalization remains
  # lightly verified and should still be checked against a sandbox account
  # before broader production use.
  class TiktokAdapter < BaseChannelAdapter
    BASE_URL = "https://open-api.tiktokglobalshop.com".freeze
    PRODUCT_SEARCH_PATH = "/product/202309/products/search".freeze
    PAGE_SIZE = 100

    # code => 0 means success; these are believed-auth-related failure
    # families (see class comment — not confirmed against real docs).
    AUTH_ERROR_KEYWORDS = %w[sign signature access_token token auth].freeze
    RATE_LIMIT_KEYWORDS = %w[rate frequency too many limit].freeze

    def authenticate
      post(PRODUCT_SEARCH_PATH, { page_size: 1 })
      true
    end

    def fetch_products
      skus = []
      page_token = nil

      loop do
        body = post(PRODUCT_SEARCH_PATH, { page_size: PAGE_SIZE, page_token: page_token }.compact)
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
      body = post("/product/202309/products/#{external_id}/inventory/search", {})
      inventories = body.dig("data", "inventories") || []
      inventories.sum { |inv| inv["quantity"].to_i }
    end

    def normalize_product(raw)
      {
        external_id:  raw["id"].to_s,
        external_sku: raw["seller_sku"] || raw["sku_id"],
        name:         raw["_product_title"],
        price:        to_decimal(raw.dig("price", "amount") || raw["price"]),
        stock_qty:    to_decimal((raw["inventory"] || []).sum { |inv| inv["quantity"].to_i }),
        raw:          raw.except("_product_title")
      }
    end

    private

    def post(path, body)
      timestamp = Time.now.to_i
      encoded_body = encode_json_body(body)
      params = { app_key: credentials[:app_key], timestamp: timestamp }
      params[:sign] = sign(path, params, encoded_body)

      response = connection(BASE_URL).post(path) do |req|
        req.params = params
        req.headers["x-tts-access-token"] = credentials[:access_token]
        req.body = encoded_body
      end

      parsed = handle_response(response)
      raise_on_body_error(parsed)
      parsed
    end

    # TikTok Shop's API returns HTTP 200 for most application-level errors
    # too, encoding the real outcome in the response body's `code` field
    # (0 = success). Best-effort classification into our shared error
    # types, since we don't have the real numeric error-code table.
    def raise_on_body_error(body)
      code = body["code"]
      return if code.nil? || code.zero?

      message = body["message"].to_s
      downcased = message.downcase

      if AUTH_ERROR_KEYWORDS.any? { |k| downcased.include?(k) }
        raise AuthenticationError, "TiktokAdapter: #{message} (code #{code})"
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
      base = params
        .except(:sign, "sign", :access_token, "access_token")
        .sort_by { |key, _value| key.to_s }
        .map { |key, value| "#{key}#{value}" }
        .join

      signable = "#{credentials[:app_secret]}#{path}#{base}#{encoded_body}#{credentials[:app_secret]}"
      OpenSSL::HMAC.hexdigest("SHA256", credentials[:app_secret].to_s, signable)
    end

    def encode_json_body(body)
      return nil if body.nil?

      JSON.generate(body)
    end
  end
end
