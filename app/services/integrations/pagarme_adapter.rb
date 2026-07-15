module Integrations
  # Pagar.me (financial gateway, not a sales channel) adapter. Doesn't
  # subclass BaseChannelAdapter — that interface is shaped around
  # products/stock, which doesn't apply here — but shares the same HTTP
  # plumbing via AdapterHttp, same as BaseErpAdapter.
  #
  # Pagar.me v5 uses the same Basic Auth shape for Orders and Payables:
  # secret key as username, blank password. Orders/Charges remain here only
  # as a compatibility helper; real fee reconciliation must come from
  # /payables because that object carries fee and anticipation_fee.
  class PagarmeAdapter
    include AdapterHttp

    BASE_URL  = "https://api.pagar.me/core/v5/".freeze
    PAGE_SIZE = 30 # Pagar.me's documented max per page

    def initialize(credentials)
      @credentials = credentials.to_h.with_indifferent_access
    end

    def authenticate
      get("payables", size: 1)
      true
    end

    # → [{ payable_id:, status:, amount:, fee_amount:,
    #      anticipation_fee_amount:, net_amount:, installment:,
    #      transaction_id:, charge_id:, recipient_id:, payment_date:,
    #      original_payment_date:, payment_method:, accrual_date:,
    #      date_created:, raw_payload: }]
    #
    # Cursor pagination only: Pagar.me is deprecating page pagination for
    # this endpoint, so the request carries forward_cursor when the API
    # returns one in the paging block.
    def fetch_payables(payment_date_from:, payment_date_to:, recipient_id: nil)
      payables = []
      cursor = nil

      loop do
        params = {
          size: PAGE_SIZE,
          "payment_date[gte]": payment_date_from.to_date.iso8601,
          "payment_date[lte]": payment_date_to.to_date.iso8601
        }
        params[:recipient_id] = recipient_id if recipient_id.present?
        params[:forward_cursor] = cursor if cursor.present?

        body = with_rate_limit_retry { get("payables", **params) }
        rows = body["data"] || []
        rows.each { |payable| payables << normalize_payable(payable) }

        cursor = next_cursor(body)
        break if rows.empty? || cursor.blank?
      end

      payables
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

    def normalize_payable(payable)
      amount = to_reais(payable["amount"])
      fee = to_reais(payable["fee"])
      anticipation_fee = to_reais(payable["anticipation_fee"])

      {
        payable_id:              payable["id"],
        status:                  payable["status"],
        amount:                  amount,
        fee_amount:              fee,
        anticipation_fee_amount: anticipation_fee,
        net_amount:              (amount - fee - anticipation_fee).round(2),
        installment:             payable["installment"]&.to_i,
        transaction_id:          payable["transaction_id"],
        charge_id:               payable["charge_id"],
        recipient_id:            payable["recipient_id"],
        payment_method:          payable["payment_method"],
        payment_date:            parse_date(payable["payment_date"])&.to_date,
        original_payment_date:   parse_date(payable["original_payment_date"])&.to_date,
        accrual_date:            parse_date(payable["accrual_date"]),
        date_created:            parse_date(payable["date_created"]),
        raw_payload:             payable
      }
    end

    def next_cursor(body)
      paging = body["paging"] || {}
      paging["forward_cursor"] ||
        paging["next"] ||
        paging.dig("cursors", "next") ||
        body["forward_cursor"]
    end

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
