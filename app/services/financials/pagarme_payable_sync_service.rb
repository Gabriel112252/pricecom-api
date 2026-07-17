module Financials
  class PagarmePayableSyncService
    DEFAULT_DAYS = 7
    DEFAULT_LOOKAHEAD_DAYS = 30
    # /orders pagina por created_since/created_until (data de CRIAÇÃO do
    # pedido), enquanto /payables pagina por payment_date (data de
    # PAGAMENTO) — o mesmo evento financeiro tem duas datas diferentes.
    # Esse lookback amplia a janela de created_since pra trás do payment_date
    # pedido, senão perderíamos o link de pedidos criados antes do período
    # (comum: parcelamento paga em datas bem depois da criação do pedido).
    DEFAULT_ORDER_LOOKBACK_DAYS = 30
    LOG_ACTION = "pagarme_payable_sync".freeze
    FEE_RATE_MISMATCH_CONFLICT_TYPE = "fee_rate_mismatch".freeze
    DEFAULT_FEE_TOLERANCE = 0.05

    Result = Struct.new(:outcome, :created_count, :updated_count, :skipped, :error_message, :from, :to, keyword_init: true) do
      def success? = outcome == :success
      def error?   = outcome == :error
    end

    def self.call(financial_source, days: nil, from: nil, to: nil, status: nil)
      new(financial_source, days: days, from: from, to: to, status: status).call
    end

    def initialize(financial_source, days: nil, from: nil, to: nil, status: nil)
      @financial_source = financial_source
      @tenant = financial_source.tenant
      @days = days.to_i.positive? ? days.to_i : configured_integer("payables_lookback_days", DEFAULT_DAYS)
      @from = parse_date(from) || inferred_from
      @to = parse_date(to) || inferred_to
      @status = status.presence
      @created = 0
      @updated = 0
      @skipped = []
      @affected_settlement_ids = []
    end

    def call
      @log = start_log
      adapter = Integrations::PagarmeAdapter.new(financial_source.credentials)
      @charge_to_order_id = build_charge_to_order_map(adapter)
      payables = adapter.fetch_payables(
        payment_date_from: from,
        payment_date_to: to,
        recipient_id: recipient_id,
        status: status
      )

      payables.each { |payable| process_payable(payable) }
      affected_settlement_ids.each { |id| recalculate_totals(FinancialSettlement.find(id)) }

      financial_source.update!(
        status: "active",
        last_synced_at: Time.current,
        settings: financial_source.settings.merge(
          "payables_last_successful_sync_at" => Time.current.iso8601,
          "payables_last_window_from" => from.iso8601,
          "payables_last_window_to" => to.iso8601
        )
      )
      finish_log(status: "success")

      result(:success)
    rescue Integrations::AuthenticationError => e
      financial_source.update!(status: "error")
      finish_log(status: "error", error_message: e.message)
      result(:error, e.message)
    rescue Integrations::RateLimitError => e
      finish_log(status: "error", error_message: "rate_limited: #{e.message}")
      result(:error, e.message)
    rescue Integrations::ApiError => e
      financial_source.update!(status: "error")
      finish_log(status: "error", error_message: e.message)
      result(:error, e.message)
    end

    private

    attr_reader :financial_source, :tenant, :days, :from, :to, :status, :created, :updated, :skipped,
      :log, :affected_settlement_ids, :charge_to_order_id

    # charge_id → external_order_id via /orders (Pagar.me v5 Orders API),
    # o mesmo vínculo que fetch_transactions já constrói (charge.code ||
    # order.code) mas nunca era usado aqui. Mais confiável que os fallbacks
    # abaixo, que dependem de outro FinancialSettlementItem já ter sido
    # linkado antes — sem bootstrap, ficavam sempre vazios num tenant novo.
    def build_charge_to_order_map(adapter)
      orders_from = from - order_lookback_days.days
      transactions = adapter.fetch_transactions(from: orders_from, to: to)

      transactions.each_with_object({}) do |tx, map|
        map[tx[:external_id]] = tx[:external_order_id] if tx[:external_id].present? && tx[:external_order_id].present?
      end
    end

    def order_lookback_days
      configured_integer("payables_order_lookback_days", DEFAULT_ORDER_LOOKBACK_DAYS)
    end

    def process_payable(payable)
      if payable[:payable_id].blank?
        @skipped << { external_id: nil, reason: "Payable sem id" }
        return
      end

      ActiveRecord::Base.transaction do
        order = find_order_for(payable)
        settlement = find_or_build_settlement(payable)
        item = upsert_settlement_item(settlement, payable, order)
        upsert_receivable(payable, item, order)
      end
    rescue => e
      @skipped << { external_id: payable[:payable_id], reason: e.message }
    end

    def upsert_receivable(payable, item, order)
      receivable = tenant.financial_receivables.find_or_initialize_by(
        financial_source: financial_source,
        payable_id: payable[:payable_id]
      )
      already_existed = receivable.persisted?

      receivable.assign_attributes(
        financial_settlement_item: item,
        order: order,
        status: payable[:status].presence || "unknown",
        amount: payable[:amount],
        fee_amount: payable[:fee_amount],
        anticipation_fee_amount: payable[:anticipation_fee_amount],
        net_amount: payable[:net_amount],
        installment: payable[:installment],
        transaction_id: payable[:transaction_id],
        charge_id: payable[:charge_id],
        recipient_id: payable[:recipient_id],
        payment_method: payable[:payment_method],
        payment_date: payable[:payment_date],
        original_payment_date: payable[:original_payment_date],
        accrual_date: payable[:accrual_date],
        date_created: payable[:date_created],
        raw_payload: payable[:raw_payload] || {}
      )
      receivable.save!

      already_existed ? (@updated += 1) : (@created += 1)
    end

    def find_or_build_settlement(payable)
      payment_date = payable[:payment_date] || Date.current
      external_id = "pagarme-payables-#{payment_date.iso8601}"

      financial_source.financial_settlements.find_or_initialize_by(external_id: external_id).tap do |settlement|
        settlement.tenant ||= tenant
        settlement.channel ||= financial_source.channel || tenant.channels.find_by(platform: "yampi")
        settlement.period_start = payment_date
        settlement.period_end = payment_date
        settlement.expected_payout_date = payment_date
        settlement.status = "pending" if settlement.status.blank?
        settlement.metadata = settlement.metadata.merge(
          "source" => "pagarme_payables",
          "provider" => "pagarme"
        )
        settlement.save!
      end
    end

    def upsert_settlement_item(settlement, payable, order)
      item = find_existing_settlement_item(payable[:payable_id]) ||
        settlement.financial_settlement_items.build(external_id: payable[:payable_id])
      previous_settlement_id = item.financial_settlement_id
      fee_amount = total_fee(payable)
      expected_fee = expected_fee_amount_for(payable)
      fee_difference = expected_fee.nil? ? nil : (fee_amount - expected_fee).round(2)

      item.assign_attributes(
        tenant: tenant,
        financial_settlement: settlement,
        order: order,
        external_order_id: external_order_id_for(order, payable),
        transaction_type: "sale",
        gross_amount: payable[:amount],
        fee_amount: fee_amount,
        net_amount: payable[:net_amount],
        expected_fee_amount: expected_fee,
        fee_difference_amount: fee_difference,
        transaction_date: payable[:accrual_date] || payable[:date_created],
        payout_date: payable[:payment_date],
        metadata: payable_metadata(item.metadata, payable)
      )
      item.save!

      # Campos independentes de expected_amount/difference_amount (usados
      # abaixo por MatchSettlementItem para reconciliação pedido x repasse)
      # — não há colisão, cada mecanismo tem suas próprias colunas.
      Financials::MatchSettlementItem.call(item)
      sync_fee_rate_conflict(item, order, fee_difference)
      track_settlement(settlement.id)
      track_settlement(previous_settlement_id) if previous_settlement_id.present? && previous_settlement_id != settlement.id
      item
    end

    # Taxa esperada pela regra negociada (PaymentFeeRule) vigente na data da
    # transação, casada por payment_method + card_brand (quando cartão) +
    # faixa de parcelamento. Sem regra cadastrada pra essa combinação,
    # retorna nil — não assume 0, que seria indistinguível de "bateu
    # certinho".
    def expected_fee_amount_for(payable)
      rule = PaymentFeeRule.find_for(
        tenant: tenant,
        payment_method: payable[:payment_method],
        card_brand: payable[:card_brand],
        installment: payable[:installment],
        date: (payable[:accrual_date] || payable[:date_created])&.to_date
      )
      return nil unless rule

      amount = payable[:amount].to_f
      rate_component = rule.rate_type == "percentage" ? amount * rule.rate_value.to_f / 100.0 : rule.rate_value.to_f
      fixed_component = rule.fixed_fee_gateway.to_f + rule.fixed_fee_antifraud.to_f
      fixed_component += rule.fixed_fee_boleto.to_f if payable[:payment_method] == "boleto"

      # anticipation_fee_amount do payable já está embutido em fee_amount
      # (ver total_fee) quando o pagamento foi antecipado (payment_date <
      # original_payment_date) — inclui o componente esperado só nesse caso,
      # pra comparar o mesmo total. withdrawal_fee não entra: é taxa de
      # saque, não de transação.
      anticipation_component = anticipated?(payable) ? amount * rule.anticipation_rate.to_f / 100.0 : 0.0

      (rate_component + fixed_component + anticipation_component).round(2)
    end

    def anticipated?(payable)
      payable[:payment_date].present? && payable[:original_payment_date].present? &&
        payable[:payment_date] < payable[:original_payment_date]
    end

    def sync_fee_rate_conflict(item, order, fee_difference)
      return if fee_difference.nil?

      if fee_difference.abs > fee_tolerance
        upsert_fee_rate_conflict(item, order, fee_difference)
      else
        resolve_fee_rate_conflict(item)
      end
    end

    def find_open_fee_rate_conflict(item)
      AuditConflict
        .where(tenant: tenant, conflict_type: FEE_RATE_MISMATCH_CONFLICT_TYPE, status: "open")
        .where("metadata ->> 'financial_settlement_item_id' = ?", item.id.to_s)
        .first
    end

    def upsert_fee_rate_conflict(item, order, fee_difference)
      conflict = find_open_fee_rate_conflict(item) || AuditConflict.new(
        tenant: tenant,
        conflict_type: FEE_RATE_MISMATCH_CONFLICT_TYPE,
        status: "open"
      )

      conflict.assign_attributes(
        order: order,
        severity: "medium",
        status: "open",
        source: "auto",
        expected_value: item.expected_fee_amount,
        actual_value: item.fee_amount,
        difference: fee_difference,
        metadata: {
          "financial_settlement_item_id" => item.id,
          "financial_settlement_id" => item.financial_settlement_id,
          "financial_source_id" => financial_source.id,
          "pagarme_payment_method" => item.metadata["pagarme_payment_method"],
          "pagarme_card_brand" => item.metadata["pagarme_card_brand"],
          "pagarme_installment" => item.metadata["pagarme_installment"]
        }
      )
      conflict.save!
    end

    def resolve_fee_rate_conflict(item)
      conflict = find_open_fee_rate_conflict(item)
      return unless conflict

      conflict.update!(status: "resolved", resolved_at: Time.current)
    end

    def fee_tolerance
      value = financial_source.settings["fee_rate_mismatch_tolerance"]
      value.to_f.positive? ? value.to_f : DEFAULT_FEE_TOLERANCE
    end

    def find_existing_settlement_item(external_id)
      FinancialSettlementItem
        .joins(:financial_settlement)
        .where(tenant: tenant, external_id: external_id)
        .where(financial_settlements: { financial_source_id: financial_source.id })
        .first
    end

    def payable_metadata(existing, payable)
      existing.to_h.merge(
        "source" => "pagarme_payables",
        "pagarme_payable_id" => payable[:payable_id],
        "pagarme_charge_id" => payable[:charge_id],
        "pagarme_transaction_id" => payable[:transaction_id],
        "pagarme_recipient_id" => payable[:recipient_id],
        "pagarme_payment_method" => payable[:payment_method],
        "pagarme_card_brand" => payable[:card_brand],
        "pagarme_status" => payable[:status],
        "pagarme_installment" => payable[:installment],
        "pagarme_fee_amount" => payable[:fee_amount],
        "pagarme_anticipation_fee_amount" => payable[:anticipation_fee_amount],
        "pagarme_payment_date" => payable[:payment_date]&.iso8601,
        "pagarme_original_payment_date" => payable[:original_payment_date]&.iso8601
      ).compact
    end

    def find_order_for(payable)
      order_from_charge_map(payable[:charge_id]) ||
        order_from_payload_reference(payable) ||
        order_from_charge_id(payable[:charge_id]) ||
        order_from_transaction_id(payable[:transaction_id])
    end

    def order_from_charge_map(charge_id)
      return nil if charge_id.blank?

      external_order_id = charge_to_order_id[charge_id]
      return nil if external_order_id.blank?

      tenant.orders.find_by(external_id: external_order_id) || tenant.orders.find_by(order_number: external_order_id)
    end

    def order_from_payload_reference(payable)
      candidate = payable.dig(:raw_payload, "order_code") ||
        payable.dig(:raw_payload, "code") ||
        payable.dig(:raw_payload, "charge", "code")
      return nil if candidate.blank?

      tenant.orders.find_by(external_id: candidate) || tenant.orders.find_by(order_number: candidate)
    end

    def order_from_charge_id(charge_id)
      return nil if charge_id.blank?

      item = FinancialSettlementItem
        .joins(:financial_settlement)
        .where(tenant: tenant)
        .where(financial_settlements: { financial_source_id: financial_source.id })
        .where("financial_settlement_items.external_id = :id OR financial_settlement_items.metadata ->> 'pagarme_charge_id' = :id", id: charge_id)
        .where.not(order_id: nil)
        .first

      item&.order
    end

    def order_from_transaction_id(transaction_id)
      return nil if transaction_id.blank?

      item = FinancialSettlementItem
        .joins(:financial_settlement)
        .where(tenant: tenant)
        .where(financial_settlements: { financial_source_id: financial_source.id })
        .where("financial_settlement_items.external_id = :id OR financial_settlement_items.metadata ->> 'pagarme_transaction_id' = :id", id: transaction_id)
        .where.not(order_id: nil)
        .first

      item&.order
    end

    def external_order_id_for(order, payable)
      order&.external_id || order&.order_number ||
        payable.dig(:raw_payload, "order_code") ||
        payable.dig(:raw_payload, "code") ||
        payable.dig(:raw_payload, "charge", "code")
    end

    def recalculate_totals(settlement)
      items = settlement.financial_settlement_items
      status_counts = items.group(:status).count
      settlement.update!(
        gross_amount: items.sum(:gross_amount),
        fee_amount: items.sum(:fee_amount),
        net_amount: items.sum(:net_amount),
        status: settlement_status_for(status_counts)
      )
    end

    def settlement_status_for(status_counts)
      total = status_counts.values.sum
      return "pending" if total.zero?
      return "paid" if status_counts.keys == [ "matched" ]
      return "disputed" if status_counts["disputed"].to_i.positive?
      return "partial" if status_counts["matched"].to_i.positive?

      "pending"
    end

    def total_fee(payable)
      (payable[:fee_amount].to_f + payable[:anticipation_fee_amount].to_f).round(2)
    end

    def track_settlement(settlement_id)
      affected_settlement_ids << settlement_id unless affected_settlement_ids.include?(settlement_id)
    end

    def recipient_id
      financial_source.settings["recipient_id"].presence ||
        financial_source.credentials["recipient_id"].presence
    end

    def configured_integer(key, fallback)
      value = financial_source.settings[key]
      value.to_i.positive? ? value.to_i : fallback
    end

    def inferred_from
      last_sync = parse_time(financial_source.settings["payables_last_successful_sync_at"])
      return last_sync.to_date - days if last_sync

      days.days.ago.to_date
    end

    def inferred_to
      configured_integer("payables_lookahead_days", DEFAULT_LOOKAHEAD_DAYS).days.from_now.to_date
    end

    def parse_date(value)
      return nil if value.blank?

      value.respond_to?(:to_date) ? value.to_date : Date.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def parse_time(value)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def start_log
      IntegrationSyncLog.create!(
        tenant: tenant,
        direction: "inbound",
        action: LOG_ACTION,
        status: "pending",
        started_at: Time.current,
        metadata: { financial_source_id: financial_source.id, from: from.iso8601, to: to.iso8601, status: status }.compact
      )
    end

    def finish_log(status:, error_message: nil)
      return unless log

      log.update!(
        status: status,
        finished_at: Time.current,
        duration_ms: ((Time.current - log.started_at) * 1000).round,
        error_message: error_message,
        metadata: log.metadata.merge(
          created_count: created,
          updated_count: updated,
          skipped_count: skipped.size,
          skipped: skipped.first(20)
        )
      )
    end

    def result(outcome, error_message = nil)
      Result.new(
        outcome: outcome,
        created_count: created,
        updated_count: updated,
        skipped: skipped,
        error_message: error_message,
        from: from,
        to: to
      )
    end
  end
end
