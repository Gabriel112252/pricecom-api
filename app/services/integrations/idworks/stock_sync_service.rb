module Integrations
  module Idworks
    # Pulls real stock figures per SKU from idworks (GET /sku — same
    # endpoint and same HTTP call as ProductCostSyncService; see
    # IdworksAdapter#fetch_products, which now also extracts the stock
    # fields), applies them onto matching Products' cached qty_* columns,
    # and records a StockSnapshot per matched product for history/audit.
    #
    # Deliberately does NOT touch ChannelProductListing#stock_qty — that's
    # per-channel stock (Yampi/Shopify/etc.), a different concept fed by
    # each channel's own ProductSyncService, not by the ERP. See
    # OrderStockDeductionService for how that one is maintained.
    #
    # QtyAvailable is applied exactly as idworks reports it, including
    # negative values — a negative balance is real overselling on the ERP
    # side and is the signal a future stock alert (Fase 2) needs, not
    # something to hide by clamping at zero.
    #
    # Only applies when DataSourceConfig has "stock" pointed at "idworks"
    # for this tenant — mirrors ProductCostSyncService/OrderSyncService's
    # per-data-type gating so a tenant that hasn't configured (or has
    # repointed) stock isn't silently synced.
    class StockSyncService
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
        unless sync_stock?
          log = start_log
          metadata = count_metadata.merge(reason: "stock não está configurado para idworks")
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
      def snapshot_created_count = @snapshot_created_count ||= 0
      def ignored = @ignored ||= []
      def unmatched = @unmatched ||= []
      def item_errors = @item_errors ||= []
      def ignored_reason_counts = @ignored_reason_counts ||= Hash.new(0)
      def matched_examples = @matched_examples ||= []
      def response_debug = @response_debug ||= []

      def sync_stock?
        DataSourceConfig.source_for(tenant, "stock") == "idworks"
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

        @matched_count = matched_count + 1
        synced_at = Time.current

        product.assign_attributes(
          qty_available: raw[:qty_available] || 0,
          qty_reserved: raw[:qty_reserved] || 0,
          qty_safety_stock: raw[:qty_safety_stock],
          abc_curve: raw[:abc_curve],
          lead_time_days: raw[:lead_time_days] || 0,
          infinite_inventory: raw[:infinite_inventory] || false,
          stock_synced_at: synced_at,
          idworks_id: raw[:idworks_id].presence || product.idworks_id
        )
        if product.changed?
          qty_available_changed = product.will_save_change_to_qty_available?
          product.save!
          @product_updated_count = product_updated_count + 1
          reevaluate_stock_alerts(product) if qty_available_changed
        end

        create_snapshot(product, raw, synced_at)
        record_matched_example(raw, product)
      end

      # qty_available moving changes every channel's free reserve (see
      # Product#free_reserve) — an old "insufficient_reserve" StockAlert
      # for this product might now have enough to actually replenish.
      # Rescued narrowly, same reasoning as ProductSyncService's own
      # evaluate_stock_alert: a bug here must never be counted as an
      # idworks stock-sync failure for this SKU.
      def reevaluate_stock_alerts(product)
        StockAlerts::EvaluationService.reevaluate_insufficient_reserves(product)
      rescue => e
        Rails.logger.error("[StockAlert] reevaluation failed for product=#{product.id}: #{e.message}")
      end

      def create_snapshot(product, raw, synced_at)
        StockSnapshot.create!(
          tenant: tenant,
          product: product,
          qty_available: raw[:qty_available],
          qty_reserved: raw[:qty_reserved],
          qty_safety_stock: raw[:qty_safety_stock],
          abc_curve: raw[:abc_curve],
          lead_time_days: raw[:lead_time_days],
          infinite_inventory: raw[:infinite_inventory] || false,
          synced_at: synced_at,
          raw_payload: raw[:raw] || {}
        )
        @snapshot_created_count = snapshot_created_count + 1
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
        Rails.logger.info("[IDWorks] stock_sync ignored sku=#{raw[:sku]} idworks_id=#{raw[:idworks_id]} reason=product_not_found")
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
        Rails.logger.info("[IDWorks] stock_sync ignored sku=#{raw[:sku].presence || '(blank)'} idworks_id=#{raw[:idworks_id]} reason=#{reason}")
        nil
      end

      def record_matched_example(raw, product)
        return if matched_examples.size >= 10

        matched_examples << {
          idworks_sku: raw[:sku],
          idworks_id: raw[:idworks_id],
          pricecom_product_id: product.id,
          pricecom_sku: product.sku,
          qty_available: raw[:qty_available].to_s,
          abc_curve: raw[:abc_curve]
        }
      end

      def start_log
        IntegrationSyncLog.create!(
          tenant: tenant,
          integration: integration,
          direction: "inbound",
          action: "idworks_stock_sync",
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
          snapshot_created_count: snapshot_created_count,
          ignored_count: ignored.size,
          ignored_reason_counts: ignored_reason_counts,
          missing_sku_count: ignored_reason_counts["missing_sku"],
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
