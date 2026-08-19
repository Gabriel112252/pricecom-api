module Integrations
  module Idworks
    # Resolves a raw idworks order (order_ref/idworks_order_id) to the
    # matching Pricecom Order — extracted out of OrderSyncService so any
    # other idworks sync (see lib/tasks/idworks_sales_channel_backfill.rake)
    # can reuse the exact same matching strategies (exact/normalized/digits,
    # Order fields vs IntegrationMapping) instead of a second, drifting copy
    # of this fairly intricate logic. Behavior unchanged from when this
    # lived inline in OrderSyncService — this is a pure extract, not a
    # rewrite.
    class OrderResolver
      def initialize(tenant:, integration:)
        @tenant = tenant
        @integration = integration
      end

      def resolve(raw_order)
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

      # Resolves a batch using a small set of SQL queries per strategy instead
      # of querying once for every Idworks order. The result for each item is
      # intentionally produced by #resolve, so matching order and diagnostics
      # stay identical to the single-order path.
      def resolve_many(raw_orders)
        raw_orders = raw_orders.to_a
        return [] if raw_orders.empty?

        @batch_match_cache = build_batch_match_cache(raw_orders)
        raw_orders.map { |raw_order| resolve(raw_order) }
      ensure
        @batch_match_cache = nil
      end

      private

      attr_reader :tenant, :integration

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

        if @batch_match_cache
          return @batch_match_cache[batch_cache_key(candidate, strategy, reference)]
        end

        order_matches(candidate, strategy, reference) + mapping_matches(candidate, strategy, reference)
      end

      def build_batch_match_cache(raw_orders)
        cache = Hash.new { |hash, key| hash[key] = [] }
        references_by_candidate = Hash.new do |hash, key|
          hash[key] = Hash.new { |strategies, strategy| strategies[strategy] = [] }
        end

        raw_orders.each do |raw_order|
          reference_candidates(raw_order).each do |candidate|
            strategies_for(candidate).each do |strategy|
              reference = strategy_reference(candidate, strategy)
              next if reference.blank?

              references_by_candidate[candidate_scope_key(candidate)][strategy] << reference
            end
          end
        end

        references_by_candidate.each do |candidate_key, references_by_strategy|
          references_by_strategy.each do |strategy, references|
            references = references.uniq
            index_batch_order_matches(cache, candidate_key, strategy, references)
            index_batch_mapping_matches(cache, candidate_key, strategy, references)
          end
        end

        cache
      end

      def index_batch_order_matches(cache, candidate_key, strategy, references)
        return unless candidate_key.first == "Order"

        clauses = %w[order_number external_id].map do |field|
          batch_field_clause(field, strategy, references)
        end
        orders = tenant.orders.where(clauses.join(" OR ")).to_a
        reference_lookup = references.each_with_object({}) { |reference, lookup| lookup[reference] = true }

        orders.each do |order|
          %w[order_number external_id].each do |field|
            reference = transformed_stored_reference(order.public_send(field), strategy)
            next unless reference_lookup[reference]

            cache[batch_cache_key_from_parts(candidate_key, strategy, reference)] << order
          end
        end
      end

      def index_batch_mapping_matches(cache, candidate_key, strategy, references)
        source, integration_scope = candidate_key
        fields = source == "IDOrder" ? %w[external_id] : %w[external_id external_code]
        relation = IntegrationMapping.where(
          tenant: tenant,
          external_type: "order",
          mappable_type: "Order"
        ).where.not(mappable_id: nil)
        relation = relation.where(integration_id: integration_scope) if integration_scope.present?
        clauses = fields.map { |field| batch_field_clause(field, strategy, references) }
        mappings = relation.where(clauses.join(" OR ")).to_a
        orders_by_id = tenant.orders.where(id: mappings.map(&:mappable_id).uniq).index_by(&:id)
        reference_lookup = references.each_with_object({}) { |reference, lookup| lookup[reference] = true }

        mappings.each do |mapping|
          order = orders_by_id[mapping.mappable_id]
          next unless order

          fields.each do |field|
            reference = transformed_stored_reference(mapping.public_send(field), strategy)
            next unless reference_lookup[reference]

            cache[batch_cache_key_from_parts(candidate_key, strategy, reference)] << order
          end
        end
      end

      def candidate_scope_key(candidate)
        [ candidate[:source], candidate[:integration_scope] ]
      end

      def batch_cache_key(candidate, strategy, reference)
        batch_cache_key_from_parts(candidate_scope_key(candidate), strategy, reference)
      end

      def batch_cache_key_from_parts(candidate_key, strategy, reference)
        [ candidate_key.first, candidate_key.last, strategy, reference ]
      end

      def batch_field_clause(field, strategy, references)
        quoted_references = references.map { |reference| tenant.class.connection.quote(reference) }.join(", ")
        "#{reference_expression(field, strategy)} IN (#{quoted_references})"
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
        "#{reference_expression(field, strategy)} = :reference"
      end

      def normalized_sql(field)
        "#{reference_expression(field, :normalized)} = :reference"
      end

      def digits_sql(field)
        "#{reference_expression(field, :digits)} = :reference"
      end

      def reference_expression(field, strategy)
        case strategy
        when :exact
          field
        when :normalized
          "REGEXP_REPLACE(UPPER(COALESCE(#{field}, '')), '[^A-Z0-9]', '', 'g')"
        when :digits
          "REGEXP_REPLACE(COALESCE(#{field}, ''), '[^0-9]', '', 'g')"
        end
      end

      def transformed_stored_reference(value, strategy)
        case strategy
        when :exact
          value.to_s.presence
        when :normalized
          normalize_reference(value).presence
        when :digits
          digits_reference(value)
        end
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
    end
  end
end
