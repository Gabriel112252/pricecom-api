module Integrations
  # Pagar.me (financial gateway, not a sales channel) adapter. Doesn't
  # subclass BaseChannelAdapter — that interface is shaped around
  # products/stock, which doesn't apply here — but shares the same HTTP
  # plumbing via AdapterHttp, same as BaseErpAdapter.
  #
  # Verified against docs.pagar.me/reference on 2026-07-10: GET
  # /core/v5/orders (Basic Auth, secret key as username/blank password),
  # `created_since`/`created_until` date filters, `page`/`size` pagination
  # with a `paging.next` cursor, amounts in BRL cents, and the order's own
  # `code` field as the merchant-supplied order reference (mapped to
  # external_order_id for Financials::MatchSettlementItem).
  #
  # NOT verified: a per-charge fee/net breakdown. The Charge object sample
  # in the accessible docs only shows id/code/amount/status/paid_at — no
  # fee field. fee_amount falls back to 0 (net_amount = gross_amount)
  # unless the API actually returns one of the candidate fee keys below.
  # Confirm against a real Pagar.me account before trusting fee_amount for
  # real reconciliation — an unnoticed 0 fee would make every settlement
  # look "disputed" against Financials::MatchSettlementItem's tolerance.
  class PagarmeAdapter
    include AdapterHttp

    BASE_URL  = "https://api.pagar.me/core/v5/".freeze
    PAGE_SIZE = 30 # Pagar.me's documented max per page

    def initialize(credentials)
      @credentials = credentials.to_h.with_indifferent_access
    end

    def authenticate
      get("orders", page: 1, size: 1)
      true
    end

    # → [{ external_id:, external_order_id:, gross_amount:, fee_amount:,
    #      net_amount:, status:, payment_date: }] — one entry per charge
    # (an order can have more than one, e.g. a retried payment).
    def fetch_transactions(from:, to:)
      transactions = []
      page = 1

      loop do
        body = with_rate_limit_retry do
          get("orders", page: page, size: PAGE_SIZE, created_since: from.to_date.iso8601, created_until: to.to_date.iso8601)
        end
        orders = body["data"] || []
        orders.each { |order| transactions.concat(charges_for(order)) }

        break if orders.empty? || body.dig("paging", "next").blank?

        page += 1
      end

      transactions
    end

    private

    attr_reader :credentials

    def charges_for(order)
      Array(order["charges"]).map { |charge| normalize_charge(order, charge) }
    end

    def normalize_charge(order, charge)
      gross = to_reais(charge["amount"])
      fee   = to_reais(charge["fee"] || charge["cost"] || charge.dig("last_transaction", "cost"))

      {
        external_id:       charge["id"],
        external_order_id: order["code"] || charge["code"],
        gross_amount:      gross,
        fee_amount:        fee,
        net_amount:        (gross - fee).round(2),
        status:            charge["status"],
        payment_date:      parse_date(charge["paid_at"] || charge["created_at"])
      }
    end

    def to_reais(cents)
      return 0.0 if cents.nil?

      (cents.to_f / 100.0).round(2)
    end

    def parse_date(val)
      return nil if val.blank?

      Time.zone.parse(val.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def get(path, **params)
      response = connection(BASE_URL).get(path, params) do |req|
        req.headers["Authorization"] = "Basic #{Base64.strict_encode64("#{credentials[:api_key]}:")}"
      end
      handle_response(response)
    end
  end
end
