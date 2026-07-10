module Integrations
  # Shopify Admin REST API. Shape verified against the public docs at
  # shopify.dev/docs/api/admin-rest/latest/resources/product on 2026-07-09
  # — NOT verified against a live store, since we have no real Shopify
  # credentials yet.
  #
  # Auth: header `X-Shopify-Access-Token`.
  # Base URL: https://{shop_domain}/admin/api/{version}
  class ShopifyAdapter < BaseChannelAdapter
    API_VERSION = "2024-01".freeze
    LIMIT = 250

    def authenticate
      get("shop.json")
      true
    end

    def fetch_products
      variants = []
      path = "products.json"
      params = { limit: LIMIT }

      loop do
        response = raw_get(path, params)
        body = handle_response(response)

        (body["products"] || []).each do |product|
          product["variants"].each do |variant|
            variants << variant.merge("_product_title" => product["title"])
          end
        end

        next_link = parse_next_link(response.headers["link"])
        break unless next_link

        path, params = next_link
      end

      variants
    end

    def fetch_stock(external_id)
      body = get("variants/#{external_id}.json")
      body.dig("variant", "inventory_quantity")
    end

    def normalize_product(raw)
      {
        external_id:  raw["id"].to_s,
        external_sku: raw["sku"],
        name:         raw["_product_title"],
        price:        to_decimal(raw["price"]),
        stock_qty:    to_decimal(raw["inventory_quantity"]),
        raw:          raw.except("_product_title")
      }
    end

    private

    def get(path, **params)
      handle_response(raw_get(path, params))
    end

    def raw_get(path, params)
      connection(base_url).get(path, params) do |req|
        req.headers["X-Shopify-Access-Token"] = credentials[:access_token]
      end
    end

    # Trailing slash matters: Faraday/URI resolves a relative request path
    # against the base URL per RFC 3986 "merge" rules — without it, the
    # base URL's own last segment (the API version) would be replaced
    # instead of extended. Hardcoded paths below are deliberately relative
    # (no leading slash) so they append correctly; the Link-header path in
    # #parse_next_link is already absolute and is used as-is.
    def base_url
      "https://#{credentials[:shop_domain]}/admin/api/#{API_VERSION}/"
    end

    # Shopify's modern cursor pagination is carried entirely in the `Link`
    # response header (page_info-based) — the old ?page=N param is
    # deprecated and no longer honored. Parses:
    #   <https://shop/admin/api/.../products.json?page_info=xyz&limit=250>; rel="next"
    def parse_next_link(link_header)
      return nil if link_header.blank?

      next_entry = link_header.split(",").find { |entry| entry.include?('rel="next"') }
      return nil unless next_entry

      url = next_entry[/<([^>]+)>/, 1]
      return nil unless url

      uri = URI.parse(url)
      [ uri.path, URI.decode_www_form(uri.query || "").to_h ]
    end
  end
end
