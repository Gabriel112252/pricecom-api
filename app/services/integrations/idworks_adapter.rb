module Integrations
  # idworks (ERP) adapter.
  #
  # IMPORTANT — UNVERIFIED: no idworks API documentation was available in
  # this environment (no attachment was provided and there's no public doc
  # site to check, unlike Yampi/Shopify/etc). The endpoint paths, auth
  # scheme, and field names below are a reasonable guess based on this
  # codebase's existing REST-adapter conventions (see YampiAdapter),
  # NOT confirmed against real idworks traffic. Treat every method here as
  # needing validation against a real idworks account/sandbox before this
  # is trusted to drive production cost/tax/invoice data — mismatched field
  # names would silently produce nil/zero costs rather than an error.
  #
  # Auth: assumed bearer token — headers `Authorization: Bearer {token}`.
  # Base URL: each tenant's own idworks instance, so unlike the sales-channel
  # adapters there's no single shared host — it's part of the credentials.
  class IdworksAdapter < BaseErpAdapter
    PER_PAGE = 100

    def authenticate
      get("products", page: 1, per_page: 1)
      true
    end

    # → [{ sku:, cost:, tax_rate: }]
    def fetch_products_with_cost
      products = []
      page = 1

      loop do
        body = with_rate_limit_retry { get("products", page: page, per_page: PER_PAGE) }
        page_products = body["data"] || []
        products.concat(page_products.map { |raw| normalize_product_cost(raw) })

        pagination = body.dig("meta", "pagination") || {}
        total_pages = pagination["total_pages"].to_i
        break if total_pages <= page || page_products.empty?

        page += 1
      end

      products
    end

    # → { nf_number:, nf_gross_value:, nf_discount:, nf_freight:,
    #     tax_amount:, real_freight_cost: } or nil when no invoice yet.
    def fetch_invoices(order_ref)
      body    = with_rate_limit_retry { get("invoices", order_ref: order_ref) }
      invoice = body["data"]
      return nil if invoice.blank?

      {
        nf_number:         invoice["nf_number"] || invoice["invoice_number"],
        nf_gross_value:    to_decimal(invoice["nf_gross_value"] || invoice["gross_value"]),
        nf_discount:       to_decimal(invoice["nf_discount"] || invoice["discount"]),
        nf_freight:        to_decimal(invoice["nf_freight"] || invoice["freight"]),
        tax_amount:        to_decimal(invoice["tax_amount"] || invoice["imposto"]),
        real_freight_cost: to_decimal(invoice["real_freight_cost"] || invoice["freight_cost"])
      }
    end

    private

    def normalize_product_cost(raw)
      {
        sku:      raw["sku"],
        cost:     to_decimal(raw["cost"] || raw["cost_price"]),
        tax_rate: to_decimal(raw["tax_rate"] || raw["icms_rate"])
      }
    end

    def get(path, **params)
      response = connection(base_url).get(path, params) do |req|
        req.headers["Authorization"] = "Bearer #{credentials[:api_key] || credentials[:token]}"
      end
      handle_response(response)
    end

    # Trailing slash matters — Faraday/URI resolves a relative path against
    # the base URL per RFC 3986 "merge" rules (see YampiAdapter's BASE_URL
    # comment for the same gotcha): without it, the base URL's own last
    # path segment would be replaced instead of extended.
    def base_url
      "#{credentials[:base_url].to_s.chomp('/')}/"
    end
  end
end
