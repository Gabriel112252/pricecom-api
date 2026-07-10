module Integrations
  # Mercado Livre (Mercado Libre) API.
  #
  # ⚠️ UNVERIFIED: developers.mercadolivre.com.br and api.mercadolibre.com
  # both returned HTTP 403 to every fetch attempt in this environment
  # (bot-protection), so — like TiktokAdapter — this is built from training
  # knowledge, not a confirmed current copy of the docs. The one thing
  # we're fairly confident about structurally: ML's item API is two-step
  # (search returns bare IDs, a separate multiget call returns full item
  # data), which is a well-known, distinctive characteristic of this
  # platform's API — so this adapter reproduces that shape rather than
  # simplifying to one call, even though the exact field names below could
  # be stale or wrong. Treat this as a placeholder to correct against the
  # real docs (or a sandbox account) before it ever runs in production.
  class MercadoLivreAdapter < BaseChannelAdapter
    BASE_URL = "https://api.mercadolibre.com/".freeze
    SEARCH_LIMIT = 50
    MULTIGET_BATCH_SIZE = 20

    def authenticate
      get("users/#{credentials[:user_id]}/items/search", limit: 1)
      true
    end

    def fetch_products
      item_ids = fetch_all_item_ids
      item_ids.each_slice(MULTIGET_BATCH_SIZE).flat_map { |batch| fetch_items(batch) }
    end

    def fetch_stock(external_id)
      body = get("items/#{external_id}", attributes: "available_quantity")
      body["available_quantity"]
    end

    def normalize_product(raw)
      {
        external_id:  raw["id"].to_s,
        external_sku: raw["seller_custom_field"] || seller_sku_attribute(raw),
        name:         raw["title"],
        price:        to_decimal(raw["price"]),
        stock_qty:    to_decimal(raw["available_quantity"]),
        raw:          raw
      }
    end

    private

    def fetch_all_item_ids
      ids = []
      offset = 0

      loop do
        body = get("users/#{credentials[:user_id]}/items/search", status: "active", offset: offset, limit: SEARCH_LIMIT)
        page_ids = body["results"] || []
        ids.concat(page_ids)

        total = body.dig("paging", "total").to_i
        offset += SEARCH_LIMIT
        break if page_ids.empty? || offset >= total
      end

      ids
    end

    # ML's multiget wraps each item in a {code, body} envelope since a
    # batch call can partially fail per-item — items that failed (code
    # != 200) are dropped rather than raising, so one bad item doesn't
    # sink the whole sync.
    def fetch_items(ids)
      body = get("items", ids: ids.join(","), attributes: "id,title,price,available_quantity,seller_custom_field,attributes")
      Array(body).filter_map { |entry| entry["body"] if entry["code"] == 200 }
    end

    def seller_sku_attribute(raw)
      Array(raw["attributes"]).find { |attr| attr["id"] == "SELLER_SKU" }&.dig("value_name")
    end

    def get(path, **params)
      response = connection(BASE_URL).get(path, params) do |req|
        req.headers["Authorization"] = "Bearer #{credentials[:access_token]}"
      end
      handle_response(response)
    end
  end
end
