module Integrations
  module Idworks
    # Keeps Order#real_freight_cost up to date from idworks' real shipping
    # cost (GET /orders, ValueShipping field — confirmed via
    # swagger.idworks.com.br on 2026-07-10). This is the correct source for
    # freight — NOT the invoice endpoints, which carry no monetary data at
    # all (see InvoiceSyncService's class comment for why that class was
    # repurposed into a stub).
    #
    # Runs incrementally (DateFrom/DateTo window, default last 2 hours) so
    # the scheduled OrderSyncJob (every 15 min) only re-fetches recent
    # activity instead of the entire order history on every tick.
    #
    # idworks has no tax rate/amount field anywhere (see
    # ProductCostSyncService's class comment) — tax_amount is never
    # touched here, and stays nil/0 until a real tax data source exists.
    #
    # Only applies when DataSourceConfig has "freight" pointed at "idworks"
    # for this tenant.
    class OrderSyncService
      DEFAULT_WINDOW = 2.hours

      Result = Struct.new(:outcome, :synced_count, :error_message, :metadata, keyword_init: true) do
        def success? = outcome == :success
        def error?   = outcome == :error
        def skipped? = outcome == :skipped
      end

      def self.call(integration, from: nil, to: nil)
        new(integration, from: from, to: to).call
      end

      def initialize(integration, from: nil, to: nil)
        @integration = integration
        @tenant      = integration.tenant
        @to          = to || Time.current
        @from        = from || (@to - DEFAULT_WINDOW)
      end

      def call
        unless freight_sync_enabled?
          log = start_log
          metadata = count_metadata.merge(reason: "freight não está configurado para idworks")
          finish_log(log, status: "skipped", metadata: metadata, errors: [])
          return Result.new(outcome: :skipped, synced_count: 0, error_message: nil, metadata: metadata)
        end

        log     = start_log
        adapter = IdworksAdapter.new(integration.credentials)
        adapter.authenticate

        sync_all(adapter)

        integration.update!(status: "connected", last_synced_at: Time.current)
        finish_log(log, status: item_errors.empty? ? "success" : "error", metadata: count_metadata, errors: item_errors)

        # An idworks order with no matching Pricecom Order is routine (not
        # every idworks order has necessarily synced into Pricecom yet) and
        # doesn't make the run a failure — only a real exception while
        # applying a matched order does.
        Result.new(
          outcome: item_errors.empty? ? :success : :error,
          synced_count: updated_count,
          error_message: item_errors.first&.fetch(:message, nil),
          metadata: count_metadata.merge(errors: item_errors)
        )
      rescue AuthenticationError => e
        integration.update!(status: "error")
        finish_log(log, status: "error", metadata: count_metadata, errors: [ { message: e.message } ])
        Result.new(outcome: :error, synced_count: 0, error_message: e.message, metadata: {})
      rescue RateLimitError => e
        finish_log(log, status: "error", metadata: count_metadata, errors: [ { message: "rate_limited: #{e.message}" } ])
        Result.new(outcome: :error, synced_count: 0, error_message: e.message, metadata: { retry_after: e.retry_after })
      rescue ApiError => e
        integration.update!(status: "error")
        finish_log(log, status: "error", metadata: count_metadata, errors: [ { message: e.message } ])
        Result.new(outcome: :error, synced_count: 0, error_message: e.message, metadata: {})
      end

      private

      attr_reader :integration, :tenant, :from, :to

      def received_count = @received_count ||= 0
      def updated_count = @updated_count ||= 0
      def ignored = @ignored ||= []
      def unmatched = @unmatched ||= []
      def item_errors = @item_errors ||= []

      def freight_sync_enabled?
        DataSourceConfig.source_for(tenant, "freight") == "idworks"
      end

      def sync_all(adapter)
        orders = adapter.fetch_orders(from: from, to: to)
        @received_count = orders.size

        orders.each do |raw_order|
          order = match_order(raw_order)

          if order.nil?
            record_unmatched(raw_order)
            next
          end
          if raw_order[:value_shipping].nil?
            record_ignored(raw_order, "sem ValueShipping")
            next
          end

          order.update!(real_freight_cost: raw_order[:value_shipping])
          Orders::RecalculateFinancials.call(order)
          @updated_count = updated_count + 1
        rescue => e
          item_errors << { idworks_ref: raw_order[:order_ref], message: e.message }
        end
      end

      # UNCONFIRMED: idworks' "Order" field is assumed to be the same
      # human-readable order reference Pricecom stores in
      # Order#order_number — mirroring how Financials::MatchSettlementItem
      # already falls back from external_id to order_number for the exact
      # same "which of our own fields does this external reference match"
      # problem. Falls back to external_id, then to idworks' own numeric
      # IDOrder as a last resort. Confirm against real idworks order data
      # before relying on this for anything but a best effort — a wrong
      # match here would silently apply the wrong order's freight cost.
      def match_order(raw_order)
        ref = raw_order[:order_ref]
        tenant.orders.find_by(order_number: ref) ||
          tenant.orders.find_by(external_id: ref) ||
          tenant.orders.find_by(external_id: raw_order[:idworks_order_id])
      end

      def start_log
        IntegrationSyncLog.create!(
          tenant: tenant,
          integration: integration,
          direction: "inbound",
          action: "idworks_order_sync",
          status: "pending",
          started_at: Time.current,
          metadata: { integration_id: integration.id, window_from: from.iso8601, window_to: to.iso8601 }
        )
      end

      def record_unmatched(raw_order)
        entry = { idworks_ref: raw_order[:order_ref] || raw_order[:idworks_order_id], reason: "pedido não encontrado no Pricecom" }
        unmatched << entry
        ignored << entry
        Rails.logger.info("[IDWorks] order_sync ignored idworks_ref=#{entry[:idworks_ref]} reason=order_not_found")
      end

      def record_ignored(raw_order, reason)
        entry = { idworks_ref: raw_order[:order_ref] || raw_order[:idworks_order_id], reason: reason }
        ignored << entry
        Rails.logger.info("[IDWorks] order_sync ignored idworks_ref=#{entry[:idworks_ref]} reason=#{reason}")
      end

      def count_metadata
        {
          received_count: received_count,
          updated_count: updated_count,
          synced_count: updated_count,
          ignored_count: ignored.size,
          unmatched_count: unmatched.size,
          error_count: item_errors.size,
          ignored: ignored.first(20),
          unmatched: unmatched.first(20)
        }
      end

      def finish_log(log, status:, metadata:, errors:)
        return unless log

        log.update!(
          status: status,
          finished_at: Time.current,
          duration_ms: ((Time.current - log.started_at) * 1000).round,
          error_message: errors.first&.fetch(:message, nil),
          metadata: log.metadata.merge(metadata).merge(error_count: errors.size, errors: errors.first(10))
        )
      end
    end
  end
end
