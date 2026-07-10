module Integrations
  # Yampi Catalog API (Admin v2). Shape verified against the public docs at
  # docs.yampi.com.br/api-reference (catalogo/produtos and catalogo/skus)
  # on 2026-07-09 — NOT verified against a live store, since we have no
  # real Yampi credentials yet.
  #
  # Auth: headers `User-Token` / `User-Secret-Key`.
  # Base URL: https://api.dooki.com.br/v2/{alias} — `alias` (the store's
  # Yampi handle) is required by the API even though it isn't one of the
  # two fields the product brief called out ("token+secret"); without it
  # there is no way to address a specific store, so it's a third required
  # credential field here.
  class YampiAdapter < BaseChannelAdapter
    # Trailing slash matters: Faraday/URI resolves a relative path against
    # the base URL per RFC 3986 "merge" rules — without it, the base URL's
    # own last segment ("v2") would be replaced instead of extended.
    BASE_URL = "https://api.dooki.com.br/v2/".freeze
    PER_PAGE = 50

    def authenticate
      get("/catalog/products", page: 1, per_page: 1)
      true
    end

    def fetch_products
      products = []
      page = 1

      loop do
        body = get("/catalog/products", page: page, per_page: PER_PAGE, include: "skus")
        page_products = body["data"] || []
        products.concat(page_products)

        pagination = body.dig("meta", "pagination") || {}
        total_pages = pagination["total_pages"].to_i
        break if total_pages <= page || page_products.empty?

        page += 1
      end

      products.flat_map { |product| skus_for(product) }
    end

    def fetch_stock(external_id)
      body = get("/catalog/skus/#{external_id}")
      sku = body["data"] || {}
      (sku["availability"] || sku["total_in_stock"]).to_i
    end

    # Pulls every order created in [since, now] for a one-off backfill (see
    # Integrations::Yampi::BackfillOrdersService). Each raw order hash is
    # already shaped exactly as Integrations::Normalizers::YampiOrderNormalizer
    # expects (verified against docs.yampi.com.br/api-reference/pedidos/
    # pedido/listar-pedidos on 2026-07-10) — no separate normalize_order
    # method here, since the shared normalizer is what both the webhook and
    # this backfill are required to funnel through.
    #
    # Pagination is assumed to follow the same page/per_page + meta.pagination
    # contract already confirmed working for /catalog/products — the Orders
    # endpoint's own docs only explicitly document a `limit` param and don't
    # rule this shape out, but this hasn't been confirmed against a live
    # store's order history. Verify against real traffic before relying on
    # it pulling more than one page.
    def fetch_orders(since:, until_date: Time.current)
      date_filter = "created_at:#{since.to_date.iso8601}|#{until_date.to_date.iso8601}"
      orders = []
      page = 1

      loop do
        body = with_rate_limit_retry do
          get("/orders", page: page, per_page: PER_PAGE, include: "items,customer,status", date: date_filter)
        end
        page_orders = body["data"] || []
        orders.concat(page_orders)

        pagination = body.dig("meta", "pagination") || {}
        total_pages = pagination["total_pages"].to_i
        break if total_pages <= page || page_orders.empty?

        page += 1
      end

      orders
    end

    def normalize_product(raw)
      {
        external_id:   raw["id"].to_s,
        external_sku:  raw["sku"],
        name:          raw["_product_name"],
        price:         to_decimal(raw["price_sale"] || raw["price"]),
        stock_qty:     to_decimal(raw["availability"] || raw["total_in_stock"]),
        raw:           raw.except("_product_name")
      }
    end

    private

    # Flattens a product into one hash per sellable SKU. Yampi's docs
    # confirm `?include=skus` embeds `skus.data[]` for variation products;
    # for a "simple" (non-variation) product we assume — per standard
    # e-commerce-platform convention, not explicitly confirmed in the
    # excerpts we could fetch — that it also carries exactly one embedded
    # SKU. If that assumption is wrong for a given store, this falls back
    # to a single record built from top-level product fields (no price,
    # since price isn't present on the product-list payload itself).
    def skus_for(product)
      skus = product.dig("skus", "data")

      if skus.present?
        skus.map { |sku| sku.merge("_product_name" => product["name"]) }
      else
        [
          {
            "id"              => product["id"],
            "sku"             => product["sku"],
            "total_in_stock"  => product["total_in_stock"],
            "_product_name"   => product["name"]
          }
        ]
      end
    end

    def get(path, **params)
      response = connection(BASE_URL).get(alias_path(path), params) do |req|
        req.headers["User-Token"]      = credentials[:token]
        req.headers["User-Secret-Key"] = credentials[:secret_key]
      end
      handle_response(response)
    end

    # No leading slash: Faraday resolves a leading-slash path as absolute
    # (dropping the connection's base "/v2" segment entirely), so this must
    # be relative to join correctly against BASE_URL.
    def alias_path(path)
      "#{credentials[:alias]}#{path}"
    end
  end
end
