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
    # The raw IDWorks order snapshot is always stored. Applying real freight
    # and the legacy Order#idworks_sales_channel enrichment remains gated by
    # DataSourceConfig("freight" => "idworks"). This keeps the comparison
    # source independent from the financial source configuration.
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
        @resolver    = OrderResolver.new(tenant: @tenant, integration: @integration)
      end

      def call
        log = start_log
        adapter = IdworksAdapter.new(integration.credentials)
        adapter.authenticate
        orders = adapter.fetch_orders(from: from, to: to)
        @response_debug = adapter.order_response_debug
        @received_count = orders.size
        @stored_count = OrderSnapshotService.persist!(integration, orders)

        unless freight_sync_enabled?
          integration.update!(status: "connected", last_synced_at: Time.current)
          metadata = count_metadata.merge(
            reason: "freight não está configurado para idworks",
            idworks_orders_stored_count: stored_count
          )
          finish_log(log, status: "skipped", metadata: metadata, errors: [])
          return Result.new(outcome: :skipped, synced_count: 0, error_message: nil, metadata: metadata)
        end

        sync_all(adapter, orders: orders)

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

      attr_reader :integration, :tenant, :from, :to, :resolver

      def received_count = @received_count ||= 0
      def stored_count = @stored_count ||= 0
      def found_count = @found_count ||= 0
      def updated_count = @updated_count ||= 0
      def recalculated_count = @recalculated_count ||= 0
      def ignored = @ignored ||= []
      def unmatched = @unmatched ||= []
      def item_errors = @item_errors ||= []
      def ignored_reason_counts = @ignored_reason_counts ||= Hash.new(0)
      def matched_examples = @matched_examples ||= []
      def response_debug = @response_debug ||= []

      def freight_sync_enabled?
        DataSourceConfig.source_for(tenant, "freight") == "idworks"
      end

      def sync_all(_adapter, orders:)

        orders.each do |raw_order|
          resolution = resolver.resolve(raw_order)

          unless resolution[:order]
            record_ignored(raw_order, resolution[:reason], resolution)
            next
          end

          order = resolution[:order]
          @found_count = found_count + 1
          apply_sales_channel(order, raw_order)

          if raw_order[:value_shipping].nil?
            record_ignored(raw_order, "invalid_shipping_value", resolution)
            next
          end

          if order.real_freight_cost == raw_order[:value_shipping]
            record_ignored(raw_order, "already_up_to_date", resolution)
            next
          end

          order.update!(real_freight_cost: raw_order[:value_shipping])
          ::Orders::RecalculateFinancials.call(order)
          @updated_count = updated_count + 1
          @recalculated_count = recalculated_count + 1
          record_matched_example(raw_order, order, resolution)
        rescue => e
          ignored_reason_counts["outros"] += 1
          item_errors << { idworks_ref: raw_order[:order_ref], message: e.message }
        end
      end

      # Tagueia Order#idworks_sales_channel (canal nativo do idworks, ver
      # IdworksAdapter#extract_channel_slug) sempre que um pedido é
      # resolvido — independente do resultado do freight abaixo, que é o
      # motivo real desta classe existir. Só a aba idworks lê esse campo
      # (Idworks::DashboardStatsService#channel_breakdown); não participa
      # de margem/financeiro, por isso update_column (sem callbacks/
      # validations, sem tocar updated_at) em vez de update!.
      def apply_sales_channel(order, raw_order)
        slug = raw_order[:sales_channel_slug]
        return if slug.blank? || order.idworks_sales_channel == slug

        order.update_column(:idworks_sales_channel, slug)
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

      def record_ignored(raw_order, reason, resolution)
        ignored_reason_counts[reason] += 1
        entry = ignored_example(raw_order, reason, resolution)
        unmatched << entry
        ignored << entry
        Rails.logger.info("[IDWorks] order_sync ignored idworks_order=#{raw_order[:order_ref]} idworks_id=#{raw_order[:idworks_order_id]} reason=#{reason} search_reference=#{resolution[:search_reference]}")
      end

      def ignored_example(raw_order, reason, resolution)
        {
          idworks_order_id: raw_order[:idworks_order_id],
          idworks_order: raw_order[:order_ref],
          search_reference: resolution[:search_reference],
          reason: reason,
          pricecom_compared_fields: resolution[:compared_fields],
          candidate_references: resolution[:candidate_references],
          attempts: Array(resolution[:attempts]).first(6),
          idworks_raw_keys: raw_order[:raw_keys]
        }
      end

      def record_matched_example(raw_order, order, resolution)
        return if matched_examples.size >= 10

        matched_examples << {
          idworks_order_id: raw_order[:idworks_order_id],
          idworks_order: raw_order[:order_ref],
          search_reference: resolution[:search_reference],
          match_source: resolution[:match_source],
          match_strategy: resolution[:match_strategy],
          pricecom_order_id: order.id,
          pricecom_order_number: order.order_number,
          pricecom_external_id: order.external_id,
          real_freight_cost: raw_order[:value_shipping].to_s
        }
      end

      def count_metadata
        {
          received_count: received_count,
          idworks_orders_stored_count: stored_count,
          found_count: found_count,
          updated_count: updated_count,
          recalculated_count: recalculated_count,
          synced_count: updated_count,
          ignored_count: ignored.size,
          ignored_reason_counts: ignored_reason_counts,
          order_not_found: ignored_reason_counts["order_not_found"],
          missing_external_reference: ignored_reason_counts["missing_external_reference"],
          invalid_shipping_value: ignored_reason_counts["invalid_shipping_value"],
          already_up_to_date: ignored_reason_counts["already_up_to_date"],
          duplicated_reference: ignored_reason_counts["duplicated_reference"],
          outros: ignored_reason_counts["outros"],
          unmatched_count: ignored_reason_counts["order_not_found"],
          error_count: item_errors.size,
          ignored: ignored.first(10),
          unmatched: unmatched.first(10),
          matched_examples: matched_examples.first(10),
          idworks_response_debug: response_debug
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
