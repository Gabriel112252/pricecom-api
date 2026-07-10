module Financials
  # Pulls Pagar.me transactions for a trailing window and reconciles them
  # against Orders — the automatic replacement for the manual CSV import
  # (FinancialSettlementsController#import). Reuses
  # Financials::MatchSettlementItem for the actual order-matching logic
  # instead of duplicating it; this service is only responsible for
  # fetching from Pagar.me and upserting the FinancialSettlement/Items.
  #
  # One FinancialSettlement per sync window (idempotent via external_id on
  # the date range), one FinancialSettlementItem per charge (idempotent via
  # external_id) — running this twice for the same window updates existing
  # items rather than duplicating them, same guarantee
  # Yampi::BackfillOrdersService gives for orders.
  class PagarmeSyncService
    DEFAULT_DAYS = 7

    Result = Struct.new(:outcome, :created_count, :updated_count, :skipped, :error_message, keyword_init: true) do
      def success? = outcome == :success
      def error?   = outcome == :error
    end

    def self.call(financial_source, days: DEFAULT_DAYS)
      new(financial_source, days: days).call
    end

    def initialize(financial_source, days: DEFAULT_DAYS)
      @financial_source = financial_source
      @tenant = financial_source.tenant
      @days   = days.to_i.positive? ? days.to_i : DEFAULT_DAYS
      @from   = @days.days.ago.to_date
      @to     = Date.current
      @created = 0
      @updated = 0
      @skipped = []
    end

    def call
      @log = start_log
      adapter = Integrations::PagarmeAdapter.new(financial_source.credentials)
      adapter.authenticate

      settlement = find_or_build_settlement
      process_transactions(settlement, adapter.fetch_transactions(from: from, to: to))
      recalculate_totals(settlement)

      financial_source.update!(status: "active", last_synced_at: Time.current)
      finish_log(status: "success")

      Result.new(outcome: :success, created_count: created, updated_count: updated, skipped: skipped, error_message: nil)
    rescue Integrations::AuthenticationError => e
      financial_source.update!(status: "error")
      finish_log(status: "error", error_message: e.message)
      Result.new(outcome: :error, created_count: created, updated_count: updated, skipped: skipped, error_message: e.message)
    rescue Integrations::RateLimitError => e
      finish_log(status: "error", error_message: "rate_limited: #{e.message}")
      Result.new(outcome: :error, created_count: created, updated_count: updated, skipped: skipped, error_message: e.message)
    rescue Integrations::ApiError => e
      financial_source.update!(status: "error")
      finish_log(status: "error", error_message: e.message)
      Result.new(outcome: :error, created_count: created, updated_count: updated, skipped: skipped, error_message: e.message)
    end

    private

    attr_reader :financial_source, :tenant, :days, :from, :to, :created, :updated, :skipped, :log

    def find_or_build_settlement
      financial_source.financial_settlements.find_or_initialize_by(external_id: "pagarme-#{from.iso8601}-#{to.iso8601}").tap do |settlement|
        settlement.tenant ||= tenant
        settlement.period_start ||= from
        settlement.period_end   ||= to
        settlement.status = "pending" if settlement.new_record?
        settlement.save!
      end
    end

    def process_transactions(settlement, transactions)
      transactions.each do |txn|
        if txn[:status] != "paid"
          @skipped << { external_id: txn[:external_id], reason: "status Pagar.me = #{txn[:status] || 'desconhecido'} (não confirmado como pago)" }
          next
        end

        upsert_item(settlement, txn)
      rescue => e
        @skipped << { external_id: txn[:external_id], reason: e.message }
      end
    end

    def upsert_item(settlement, txn)
      already_existed = settlement.financial_settlement_items.exists?(external_id: txn[:external_id])
      item = settlement.financial_settlement_items.find_or_initialize_by(external_id: txn[:external_id])

      item.assign_attributes(
        tenant:             tenant,
        external_order_id:  txn[:external_order_id],
        transaction_type:   "sale",
        gross_amount:       txn[:gross_amount],
        fee_amount:         txn[:fee_amount],
        net_amount:         txn[:net_amount],
        transaction_date:   txn[:payment_date]
      )
      item.save!

      Financials::MatchSettlementItem.call(item)
      already_existed ? (@updated += 1) : (@created += 1)
    end

    def recalculate_totals(settlement)
      items = settlement.financial_settlement_items
      settlement.update!(
        gross_amount: items.sum(:gross_amount),
        fee_amount:   items.sum(:fee_amount),
        net_amount:   items.sum(:net_amount)
      )
    end

    def start_log
      IntegrationSyncLog.create!(
        tenant:      tenant,
        direction:   "inbound",
        action:      "pagarme_settlement_sync",
        status:      "pending",
        started_at:  Time.current,
        metadata:    { financial_source_id: financial_source.id, days: days }
      )
    end

    def finish_log(status:, error_message: nil)
      log.update!(
        status:        status,
        finished_at:   Time.current,
        duration_ms:   ((Time.current - log.started_at) * 1000).round,
        error_message: error_message,
        metadata:      log.metadata.merge(created_count: created, updated_count: updated, skipped_count: skipped.size, skipped: skipped.first(20))
      )
    end
  end
end
