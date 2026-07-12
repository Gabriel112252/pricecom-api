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

      def sync_all(adapter)
        orders = adapter.fetch_orders(from: from, to: to)
        @response_debug = adapter.order_response_debug
        @received_count = orders.size

        orders.each do |raw_order|
          resolution = resolve_order(raw_order)

          unless resolution[:order]
            record_ignored(raw_order, resolution[:reason], resolution)
            next
          end

          order = resolution[:order]
          @found_count = found_count + 1

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

      def resolve_order(raw_order)
        candidates = reference_candidates(raw_order)
        return resolution_failure("missing_external_reference", raw_order, candidates) if candidates.empty?

        attempts = []

        candidates.each do |candidate|
          strategies_for(candidate).each do |strategy|
            matches = lookup_matches(candidate, strategy)
            attempts << attempt_metadata(candidate, strategy, matches)
            unique_orders = matches.map(&:itself).uniq(&:id)

            if unique_orders.size > 1
              return resolution_failure("duplicated_reference", raw_order, candidates, attempts: attempts)
            end

            if unique_orders.one?
              return {
                order: unique_orders.first,
                reason: nil,
                search_reference: strategy_reference(candidate, strategy),
                match_source: candidate[:source],
                match_strategy: strategy,
                compared_fields: compared_fields_for(candidate, strategy),
                candidate_references: candidates.map { |c| c.slice(:source, :value) },
                attempts: attempts
              }
            end
          end
        end

        resolution_failure("order_not_found", raw_order, candidates, attempts: attempts)
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

      def resolution_failure(reason, raw_order, candidates, attempts: [])
        {
          order: nil,
          reason: reason,
          search_reference: candidates.first&.fetch(:value, nil),
          compared_fields: default_compared_fields,
          candidate_references: candidates.map { |c| c.slice(:source, :value) },
          attempts: attempts,
          idworks_order_id: raw_order[:idworks_order_id],
          idworks_order: raw_order[:order_ref]
        }
      end

      def reference_candidates(raw_order)
        [
          {
            source: "Order",
            value: clean_reference(raw_order[:order_ref]),
            fields: %w[orders.order_number orders.external_id integration_mappings.external_id integration_mappings.external_code],
            integration_scope: nil,
            normalized: true
          },
          {
            source: "IDOrder",
            value: clean_reference(raw_order[:idworks_order_id]),
            fields: %w[integration_mappings.external_id],
            integration_scope: integration.id,
            normalized: false
          }
        ].select { |candidate| candidate[:value].present? }
      end

      def strategies_for(candidate)
        strategies = [ :exact ]
        strategies << :normalized if candidate[:normalized] && normalize_reference(candidate[:value]) != candidate[:value]
        strategies << :digits if candidate[:normalized] && digits_reference(candidate[:value]).present?
        strategies.uniq
      end

      def lookup_matches(candidate, strategy)
        reference = strategy_reference(candidate, strategy)
        return [] if reference.blank?

        order_matches(candidate, strategy, reference) + mapping_matches(candidate, strategy, reference)
      end

      def order_matches(candidate, strategy, reference)
        clauses = []
        values = { reference: reference }

        if candidate[:fields].include?("orders.order_number")
          clauses << order_field_clause("order_number", strategy)
        end

        if candidate[:fields].include?("orders.external_id")
          clauses << order_field_clause("external_id", strategy)
        end

        return [] if clauses.empty?

        tenant.orders.where(clauses.join(" OR "), values).to_a
      end

      def mapping_matches(candidate, strategy, reference)
        mapping_fields = candidate[:fields].grep(/\Aintegration_mappings\./)
        return [] if mapping_fields.empty?

        relation = IntegrationMapping.where(
          tenant: tenant,
          external_type: "order",
          mappable_type: "Order"
        ).where.not(mappable_id: nil)
        relation = relation.where(integration_id: candidate[:integration_scope]) if candidate[:integration_scope].present?

        clauses = mapping_fields.map { |field| order_field_clause(field.delete_prefix("integration_mappings."), strategy) }
        relation = relation.where(clauses.join(" OR "), reference: reference)

        tenant.orders.where(id: relation.select(:mappable_id)).to_a
      end

      def order_field_clause(field, strategy)
        case strategy
        when :exact
          "#{field} = :reference"
        when :normalized
          normalized_sql(field)
        when :digits
          digits_sql(field)
        end
      end

      def normalized_sql(field)
        "REGEXP_REPLACE(UPPER(COALESCE(#{field}, '')), '[^A-Z0-9]', '', 'g') = :reference"
      end

      def digits_sql(field)
        "REGEXP_REPLACE(COALESCE(#{field}, ''), '[^0-9]', '', 'g') = :reference"
      end

      def strategy_reference(candidate, strategy)
        case strategy
        when :exact
          candidate[:value]
        when :normalized
          normalize_reference(candidate[:value])
        when :digits
          digits_reference(candidate[:value])
        end
      end

      def attempt_metadata(candidate, strategy, matches)
        {
          source: candidate[:source],
          strategy: strategy,
          reference: strategy_reference(candidate, strategy),
          compared_fields: compared_fields_for(candidate, strategy),
          matches_count: matches.map(&:id).uniq.size,
          matched_order_ids: matches.map(&:id).uniq.first(5)
        }
      end

      def compared_fields_for(candidate, strategy)
        candidate[:fields].map { |field| "#{field}:#{strategy}" }
      end

      def default_compared_fields
        %w[
          orders.order_number:exact
          orders.external_id:exact
          integration_mappings.external_id:exact
          integration_mappings.external_code:exact
          orders.order_number:normalized
          orders.external_id:normalized
          integration_mappings.external_id:normalized
          integration_mappings.external_code:normalized
        ]
      end

      def clean_reference(value)
        value.to_s.strip.presence
      end

      def normalize_reference(value)
        clean_reference(value).to_s.upcase.gsub(/[^A-Z0-9]/, "")
      end

      def digits_reference(value)
        digits = clean_reference(value).to_s.gsub(/[^0-9]/, "")
        digits.length >= 4 ? digits : nil
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
