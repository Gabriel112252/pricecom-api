module Financials
  class PagarmePayableSyncService
    DEFAULT_DAYS = 7
    DEFAULT_LOOKAHEAD_DAYS = 30
    LOG_ACTION = "pagarme_payable_sync".freeze

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
      :log, :affected_settlement_ids

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

      item.assign_attributes(
        tenant: tenant,
        financial_settlement: settlement,
        order: order,
        external_order_id: external_order_id_for(order, payable),
        transaction_type: "sale",
        gross_amount: payable[:amount],
        fee_amount: total_fee(payable),
        net_amount: payable[:net_amount],
        transaction_date: payable[:accrual_date] || payable[:date_created],
        payout_date: payable[:payment_date],
        metadata: payable_metadata(item.metadata, payable)
      )
      item.save!

      Financials::MatchSettlementItem.call(item)
      track_settlement(settlement.id)
      track_settlement(previous_settlement_id) if previous_settlement_id.present? && previous_settlement_id != settlement.id
      item
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
        "pagarme_status" => payable[:status],
        "pagarme_installment" => payable[:installment],
        "pagarme_fee_amount" => payable[:fee_amount],
        "pagarme_anticipation_fee_amount" => payable[:anticipation_fee_amount],
        "pagarme_payment_date" => payable[:payment_date]&.iso8601,
        "pagarme_original_payment_date" => payable[:original_payment_date]&.iso8601
      ).compact
    end

    def find_order_for(payable)
      order_from_payload_reference(payable) ||
        order_from_charge_id(payable[:charge_id]) ||
        order_from_transaction_id(payable[:transaction_id])
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
