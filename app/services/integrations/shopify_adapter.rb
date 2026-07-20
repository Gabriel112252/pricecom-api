module Integrations
  # Shopify Admin REST API. Shape verified against the public docs at
  # shopify.dev/docs/api/admin-rest/latest/resources/product on 2026-07-09
  # — NOT verified against a live store, since we have no real Shopify
  # credentials yet.
  #
  # Auth: header `X-Shopify-Access-Token`.
  # Base URL: https://{shop_domain}/admin/api/{version}
  #
  # #update_stock (added 2026-07-20) writes via the InventoryLevel resource
  # — confirmed at shopify.dev/docs/api/admin-rest/latest/resources/
  # inventorylevel, also not verified against a live store.
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

    # Writes an absolute inventory level via
    # POST inventory_levels/set.json (not /adjust.json — we always know the
    # desired final quantity here, not a delta, and `set` is the endpoint
    # meant for that per shopify.dev/docs/api/admin-rest/latest/resources/
    # inventorylevel, confirmed 2026-07-20).
    #
    # `inventory_item_id` (NOT the variant id) is required by this endpoint
    # and is a plain field on every variant Shopify already returns from
    # #fetch_products (confirmed against shopify.dev's Product resource) —
    # #normalize_product now persists it as external_inventory_item_id, so
    # the caller resolves it from ChannelProductListing rather than this
    # method doing an extra live lookup. `external_id` is kept only for
    # parity with the common #update_stock interface/error messages, not
    # used in the request itself.
    #
    # `location_id` has no per-SKU equivalent — it's a store-wide concept
    # (GET locations.json) most stores have exactly one of, but Shopify
    # allows several (including "legacy" fulfillment-service locations we
    # must not write to). Deliberately resolved live and memoized per
    # adapter instance instead of persisted: unlike inventory_item_id, it's
    # identical for every listing in a store, so caching it on every
    # ChannelProductListing row would just be redundant data to keep in
    # sync. Raises rather than guessing if more than one candidate location
    # is active and non-legacy — same "don't invent an id" rule as Yampi's
    # blocked #update_stock.
    def update_stock(external_id:, quantity:, inventory_item_id:)
      body = post("inventory_levels/set.json", {
        location_id:        resolve_location_id,
        inventory_item_id:  inventory_item_id.to_i,
        available:          quantity.to_i
      })
      body.dig("inventory_level", "available")
    end

    def normalize_product(raw)
      {
        external_id:                raw["id"].to_s,
        external_sku:               raw["sku"],
        name:                       raw["_product_title"],
        price:                      to_decimal(raw["price"]),
        stock_qty:                  to_decimal(raw["inventory_quantity"]),
        external_inventory_item_id: raw["inventory_item_id"]&.to_s,
        raw:                        raw.except("_product_title")
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

    def post(path, body)
      response = connection(base_url).post(path) do |req|
        req.headers["X-Shopify-Access-Token"] = credentials[:access_token]
        req.body = body
      end
      handle_response(response)
    end

    # Memoized per adapter instance (same lifetime as the auth token would
    # be, if this adapter cached one) — a batch of stock writes in one sync
    # run pays for this lookup once, not once per SKU.
    def resolve_location_id
      @location_id ||= begin
        locations = get("locations.json")["locations"] || []
        candidates = locations.select { |loc| loc["active"] && !loc["legacy"] }

        if candidates.size != 1
          raise ApiError,
            "ShopifyAdapter#update_stock: expected exactly one active, non-legacy location, " \
            "found #{candidates.size} — pick one explicitly instead of guessing"
        end

        candidates.first["id"]
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
