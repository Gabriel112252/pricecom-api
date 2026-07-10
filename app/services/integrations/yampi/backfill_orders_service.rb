module Integrations
  module Yampi
    # One-off pull of Yampi orders created in the last N days — the webhook
    # only fires for orders placed after it was registered, so history from
    # before that point needs to be pulled explicitly via the Orders API.
    #
    # Mirrors ProductSyncService's shape (IntegrationSyncLog bookkeeping,
    # AuthenticationError/RateLimitError/ApiError handling) but funnels every
    # order through the exact same Integrations::Processors::YampiOrderProcessor
    # the webhook uses, so there's exactly one place that decides
    # order-vs-refund and does the upsert — see YampiOrderProcessor and
    # Integrations::Orders::UpsertOrder. Idempotent via Order#external_id:
    # an order already created by the webhook (or a previous backfill run)
    # is updated in place, never duplicated, and OrderStockDeductionService's
    # own stock_deducted_at guard (reused unchanged) prevents a double
    # stock debit for whichever of the two ran first.
    class BackfillOrdersService
      DEFAULT_DAYS = 30

      # Stand-in for an IntegrationEvent: YampiOrderProcessor and
      # YampiOrderNormalizer only ever read #tenant, #payload, #event_type
      # and #integration off whatever they're given, so a persisted
      # IntegrationEvent (and the async ProcessEventJob machinery built for
      # webhook delivery) isn't needed for this synchronous, admin-triggered
      # pull.
      BackfillEvent = Struct.new(:tenant, :payload, :event_type, :integration, keyword_init: true)

      Result = Struct.new(:outcome, :created_count, :updated_count, :skipped, :error_message, keyword_init: true) do
        def success? = outcome == :success
        def error?   = outcome == :error
      end

      def self.call(channel_credential, days: DEFAULT_DAYS)
        new(channel_credential, days: days).call
      end

      def initialize(channel_credential, days: DEFAULT_DAYS)
        @channel_credential = channel_credential
        @tenant             = channel_credential.tenant
        @days               = days.to_i.positive? ? days.to_i : DEFAULT_DAYS
        @integration        = @tenant.integrations.active.find_by(provider: "yampi")
        @created = 0
        @updated = 0
        @skipped = []
      end

      def call
        @log = start_log
        adapter = Integrations::YampiAdapter.new(channel_credential.credentials)
        adapter.authenticate

        process_orders(adapter.fetch_orders(since: days.days.ago))

        finish_log(status: "success")
        Result.new(outcome: :success, created_count: created, updated_count: updated, skipped: skipped, error_message: nil)
      rescue AuthenticationError => e
        channel_credential.update!(status: "error")
        finish_log(status: "error", error_message: e.message)
        Result.new(outcome: :error, created_count: created, updated_count: updated, skipped: skipped, error_message: e.message)
      rescue RateLimitError => e
        finish_log(status: "error", error_message: "rate_limited: #{e.message}")
        Result.new(outcome: :error, created_count: created, updated_count: updated, skipped: skipped, error_message: e.message)
      rescue ApiError => e
        finish_log(status: "error", error_message: e.message)
        Result.new(outcome: :error, created_count: created, updated_count: updated, skipped: skipped, error_message: e.message)
      end

      private

      attr_reader :channel_credential, :tenant, :days, :integration, :created, :updated, :skipped

      def process_orders(raw_orders)
        seen_external_ids = Set.new

        raw_orders.each do |raw_order|
          external_id = (raw_order["id"] || raw_order["order_id"])&.to_s

          if external_id.blank?
            @skipped << { external_id: nil, reason: "sem identificador externo" }
            next
          end

          # Guards against a page-boundary overlap returning the same order
          # twice within one run — a real duplicate, not just "already
          # existed from a previous run" (that case is a normal update).
          if seen_external_ids.include?(external_id)
            @skipped << { external_id: external_id, reason: "duplicado na mesma importação" }
            next
          end
          seen_external_ids << external_id

          process_order(raw_order, external_id)
        end
      end

      def process_order(raw_order, external_id)
        already_existed = tenant.orders.exists?(external_id: external_id)

        event  = BackfillEvent.new(tenant: tenant, payload: raw_order, event_type: "order.backfill", integration: integration)
        result = Integrations::Processors::YampiOrderProcessor.call(event)

        if result.outcome == :success
          already_existed ? (@updated += 1) : (@created += 1)
        else
          @skipped << { external_id: external_id, reason: result.error_message || "erro desconhecido" }
        end
      end

      def start_log
        IntegrationSyncLog.create!(
          tenant:      tenant,
          integration: integration,
          direction:   "inbound",
          action:      "order_backfill",
          status:      "pending",
          started_at:  Time.current,
          metadata:    { channel: "yampi", channel_credential_id: channel_credential.id, days: days }
        )
      end

      def finish_log(status:, error_message: nil)
        log.update!(
          status:        status,
          finished_at:   Time.current,
          duration_ms:   ((Time.current - log.started_at) * 1000).round,
          error_message: error_message,
          metadata:      log.metadata.merge(
            created_count: created,
            updated_count: updated,
            skipped_count: skipped.size,
            skipped:       skipped.first(20)
          )
        )
      end

      attr_reader :log
    end
  end
end
