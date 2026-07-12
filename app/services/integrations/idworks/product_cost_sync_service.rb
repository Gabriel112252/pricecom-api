module Integrations
  module Idworks
    # Pulls real cost per SKU from idworks (GET /sku), applies it onto
    # matching Products, then propagates the unit cost to matching order items
    # and recalculates the affected orders.
    #
    # Cost field priority (confirmed via swagger.idworks.com.br on
    # 2026-07-10): CostSet only appears on the /sku/{IDSku} detail
    # endpoint (would cost one HTTP call per SKU on a paginated sync — not
    # worth it for the default flow) and is deliberately NOT used here.
    # CostLastPurchase is preferred, CostAverage as fallback (often 0), 0 if
    # neither is present. This priority is currently hardcoded rather than
    # driven by DataSourceConfig — the task that introduced this
    # explicitly allows simplifying to a fixed fallback for the MVP.
    #
    # tax_rate is NOT synced here (and never was, correctly) — idworks has
    # no percentage tax-rate field on either /sku endpoint, only fiscal
    # classification (SkuNCM/IDTaxDepartment/TaxDepartmentDescription/
    # SkuCst), which isn't a usable tax_rate. Product#tax_rate is left
    # exactly as-is until a real tax data source exists.
    #
    # Only applies cost when DataSourceConfig has "cost" pointed at
    # "idworks" for this tenant — a tenant that's repointed cost elsewhere
    # shouldn't have idworks silently overwrite it.
    class ProductCostSyncService
      Result = Struct.new(:outcome, :synced_count, :error_message, :metadata, keyword_init: true) do
        def success? = outcome == :success
        def error?   = outcome == :error
        def skipped? = outcome == :skipped
      end

      def self.call(integration)
        new(integration).call
      end

      def initialize(integration)
        @integration = integration
        @tenant      = integration.tenant
      end

      def call
        unless sync_cost?
          log = start_log
          metadata = count_metadata.merge(reason: "cost não está configurado para idworks")
          finish_log(log, status: "skipped", metadata: metadata, errors: [])
          return Result.new(outcome: :skipped, synced_count: 0, error_message: nil, metadata: metadata)
        end

        log     = start_log
        adapter = IdworksAdapter.new(integration.credentials)
        adapter.authenticate

        sync_all(adapter)

        integration.update!(status: "connected", last_synced_at: Time.current)
        finish_log(log, status: item_errors.empty? ? "success" : "error", metadata: count_metadata, errors: item_errors)

        Result.new(
          outcome: item_errors.empty? ? :success : :error,
          synced_count: matched_count,
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

      attr_reader :integration, :tenant

      def received_count = @received_count ||= 0
      def matched_count = @matched_count ||= 0
      def product_updated_count = @product_updated_count ||= 0
      def order_items_updated_count = @order_items_updated_count ||= 0
      def orders_recalculated_count = @orders_recalculated_count ||= 0
      def ignored = @ignored ||= []
      def unmatched = @unmatched ||= []
      def item_errors = @item_errors ||= []
      def ignored_reason_counts = @ignored_reason_counts ||= Hash.new(0)
      def matched_examples = @matched_examples ||= []
      def response_debug = @response_debug ||= []

      def sync_cost?
        DataSourceConfig.source_for(tenant, "cost") == "idworks"
      end

      def sync_all(adapter)
        products = adapter.fetch_products
        @response_debug = adapter.product_response_debug
        @received_count = products.size

        products.each do |raw|
          if raw[:sku].blank?
            record_ignored(raw, "missing_sku")
            next
          end

          apply_to_product(raw)
        rescue => e
          item_errors << { sku: raw[:sku], message: e.message }
        end
      end

      def apply_to_product(raw)
        product = tenant.products.find_by(sku: raw[:sku])
        return record_unmatched(raw) unless product

        cost = raw[:cost_last_purchase].nil? ? raw[:cost_average] : raw[:cost_last_purchase]
        return record_ignored(raw, "missing_cost") if cost.nil?

        @matched_count = matched_count + 1

        product.assign_attributes(cost_price: cost, idworks_id: raw[:idworks_id].presence || product.idworks_id)
        if product.changed?
          product.save!
          @product_updated_count = product_updated_count + 1
        end
        record_matched_example(raw, product, cost)

        item_updates, order_updates = apply_cost_to_orders(product, cost)
        @order_items_updated_count = order_items_updated_count + item_updates
        @orders_recalculated_count = orders_recalculated_count + order_updates
      end

      def apply_cost_to_orders(product, cost)
        updated_items = 0
        order_ids = []

        matching_items_for(product).where(is_gift: false).find_each do |item|
          changed = false

          if item.product_id.blank?
            item.product = product
            changed = true
          end

          if item.unit_cost != cost
            item.unit_cost = cost
            changed = true
          end

          if changed
            item.save!
            updated_items += 1
            order_ids << item.order_id
          end
        end

        recalculated_orders = recalculate_orders(order_ids)
        [ updated_items, recalculated_orders ]
      end

      def matching_items_for(product)
        OrderItem.joins(:order)
          .where(orders: { tenant_id: tenant.id })
          .where("order_items.product_id = :product_id OR order_items.sku = :sku", product_id: product.id, sku: product.sku)
      end

      def recalculate_orders(order_ids)
        count = 0
        tenant.orders.where(id: order_ids.uniq).find_each do |order|
          ::Orders::RecalculateFinancials.call(order)
          count += 1
        end
        count
      end

      def record_unmatched(raw)
        ignored_reason_counts["product_not_found"] += 1
        entry = {
          sku: raw[:sku],
          idworks_id: raw[:idworks_id],
          reason: "product_not_found",
          idworks_raw_keys: raw[:raw_keys]
        }
        unmatched << entry
        ignored << entry
        Rails.logger.info("[IDWorks] product_cost_sync ignored sku=#{raw[:sku]} idworks_id=#{raw[:idworks_id]} reason=product_not_found")
        nil
      end

      def record_ignored(raw, reason)
        ignored_reason_counts[reason] += 1
        entry = {
          sku: raw[:sku],
          idworks_id: raw[:idworks_id],
          reason: reason,
          idworks_raw_keys: raw[:raw_keys]
        }
        ignored << entry
        Rails.logger.info("[IDWorks] product_cost_sync ignored sku=#{raw[:sku].presence || '(blank)'} idworks_id=#{raw[:idworks_id]} reason=#{reason}")
        nil
      end

      def record_matched_example(raw, product, cost)
        return if matched_examples.size >= 10

        matched_examples << {
          idworks_sku: raw[:sku],
          idworks_id: raw[:idworks_id],
          pricecom_product_id: product.id,
          pricecom_sku: product.sku,
          cost_price: cost.to_s
        }
      end

      def start_log
        IntegrationSyncLog.create!(
          tenant: tenant,
          integration: integration,
          direction: "inbound",
          action: "idworks_product_cost_sync",
          status: "pending",
          started_at: Time.current,
          metadata: { integration_id: integration.id }
        )
      end

      def count_metadata
        {
          received_count: received_count,
          matched_count: matched_count,
          synced_count: matched_count,
          product_updated_count: product_updated_count,
          order_items_updated_count: order_items_updated_count,
          orders_recalculated_count: orders_recalculated_count,
          ignored_count: ignored.size,
          ignored_reason_counts: ignored_reason_counts,
          missing_sku_count: ignored_reason_counts["missing_sku"],
          missing_cost_count: ignored_reason_counts["missing_cost"],
          product_not_found_count: ignored_reason_counts["product_not_found"],
          unmatched_count: unmatched.size,
          error_count: item_errors.size,
          ignored: ignored.first(20),
          unmatched: unmatched.first(20),
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
