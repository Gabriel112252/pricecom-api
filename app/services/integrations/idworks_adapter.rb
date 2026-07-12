module Integrations
  # idworks (ERP) adapter — CONFIRMED against the tenant's real idworks
  # Swagger spec (swagger.idworks.com.br) on 2026-07-10: base URL
  # https://hidrabene.api-idworks.com.br/1.0/, GET /sku (paginated product
  # list, "Page" param), GET /orders (paginated, DateFrom/DateTo filters).
  # Auth is delegated entirely to Idworks::BaseClient/Idworks::AuthService
  # (POST user/signin/local -> Bearer token + Origin/FilePath headers on
  # every call) rather than reimplemented here.
  #
  # STILL UNVERIFIED (not covered in the Swagger fields relayed to this
  # environment — confirm before trusting in production):
  #   - the exact pagination response envelope: assumed to be either a bare
  #     array or a { "Data" => [...] } wrapper, stopping once a page comes
  #     back empty. If idworks instead returns e.g. an explicit TotalPages
  #     field and an empty final page is never actually empty, this could
  #     under/over-fetch.
  #   - the plain SKU-code field name on /sku records: guessed as "Sku"
  #     (falling back to IDSku). Note Product#idworks_id already exists as
  #     a column but nothing currently reads/writes it — IDSku might be the
  #     intended match key instead of the sku string; out of scope to
  #     change here without being asked, but worth revisiting.
  #   - DateFrom/DateTo's exact format/timezone for GET /orders — assumed
  #     full ISO8601 timestamps (a date-only filter would be useless for
  #     OrderSyncService's 2-hour polling window).
  class IdworksAdapter < BaseErpAdapter
    def initialize(credentials)
      super
      @client = Idworks::BaseClient.new(credentials)
    end

    def authenticate
      client.authenticate!
    end

    # → [{ idworks_id:, sku:, cost_last_purchase:, cost_average: }]
    def fetch_products
      products = []
      page = 1

      loop do
        body  = with_rate_limit_retry { client.get("sku", "Page" => page) }
        items = extract_list(body)
        break if items.blank?

        products.concat(items.map { |raw| normalize_product(raw) })
        page += 1
      end

      products
    end

    # → [{ order_ref:, idworks_order_id:, value_shipping:, value_product:,
    #      value_order:, value_paid: }]
    def fetch_orders(from:, to:)
      orders = []
      page = 1

      loop do
        body = with_rate_limit_retry do
          client.get("orders", "Page" => page, "DateFrom" => from.iso8601, "DateTo" => to.iso8601)
        end
        items = extract_list(body)
        break if items.blank?

        orders.concat(items.map { |raw| normalize_order(raw) })
        page += 1
      end

      orders
    end

    private

    attr_reader :client

    def extract_list(body)
      return body if body.is_a?(Array)

      body["Data"] || body["data"] || []
    end

    def normalize_product(raw)
      {
        idworks_id:         raw["IDSku"]&.to_s,
        sku:                raw["Sku"]&.to_s,
        cost_last_purchase: to_decimal(raw["CostLastPurchase"]),
        cost_average:       to_decimal(raw["CostAverage"])
      }
    end

    def normalize_order(raw)
      {
        order_ref:        raw["Order"]&.to_s,
        idworks_order_id: raw["IDOrder"]&.to_s,
        value_shipping:   to_decimal(raw["ValueShipping"]),
        value_product:    to_decimal(raw["ValueProduct"]),
        value_order:      to_decimal(raw["ValueOrder"]),
        value_paid:       to_decimal(raw["ValuePaid"])
      }
    end
  end
end
