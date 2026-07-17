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

    BASE_URL = "https://api.pagar.me/core/v5/".freeze
    ORDERS_PAGE_SIZE = 30
    PAYABLES_PAGE_SIZE = 1_000

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
    #      original_payment_date:, payment_method:, card_brand:,
    #      originator_model:, accrual_date:, date_created:, raw_payload: }]
    #
    # Cursor pagination only: Pagar.me is deprecating page pagination for
    # this endpoint, so the request carries forward_cursor when the API
    # returns one in the paging block.
    def fetch_payables(payment_date_from:, payment_date_to:, recipient_id: nil, status: nil)
      payables = []
      cursor = nil

      loop do
        params = {
          size: PAYABLES_PAGE_SIZE,
          payment_date_since: payment_date_from.to_date.iso8601,
          payment_date_until: payment_date_to.to_date.iso8601
        }
        params[:recipient_id] = recipient_id if recipient_id.present?
        params[:status] = status if status.present?
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
          get("orders", page: page, size: ORDERS_PAGE_SIZE, created_since: from.to_date.iso8601, created_until: to.to_date.iso8601)
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
        card_brand:              extract_card_brand(payable),
        # Confirmado em produção (2026-07-17): payable de estorno vem com
        # originator_model: "refund" e amount negativo (dinheiro saindo).
        # Só "refund" foi observado até agora — qualquer outro valor (ou
        # nil) é tratado como venda normal em
        # PagarmePayableSyncService#transaction_type_for, sem inventar
        # mapeamento pra originator_model ainda não visto.
        originator_model:        payable["originator_model"],
        payment_date:            parse_date(payable["payment_date"])&.to_date,
        original_payment_date:   parse_date(payable["original_payment_date"])&.to_date,
        # Confirmado via payables.first[:raw_payload].keys em produção
        # (2026-07-17): o payload real usa "accrual_at"/"created_at", não
        # "accrual_date"/"date_created" — os nomes antigos nunca bateram
        # com nenhum payload visto, então transaction_date ficava sempre
        # nil em FinancialSettlementItem. Sem fallback pros nomes antigos
        # de propósito: não é um formato alternativo, é o campo errado.
        accrual_date:            parse_date(payable["accrual_at"]),
        date_created:            parse_date(payable["created_at"]),
        raw_payload:             payable
      }
    end

    # Best-effort: a forma exata do objeto card no /payables (vs. o card
    # embarcado em charges) ainda não foi confirmada contra um payload real
    # de produção — como o promocode da Yampi, mantém fallback defensivo em
    # vez de assumir um único caminho. nil (não bloqueado) quando ausente,
    # ex: pix/boleto não têm bandeira.
    def extract_card_brand(payable)
      brand = payable.dig("card", "brand") ||
        payable.dig("last_transaction", "card", "brand") ||
        payable.dig("charge", "last_transaction", "card", "brand")

      brand.to_s.downcase.presence
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
