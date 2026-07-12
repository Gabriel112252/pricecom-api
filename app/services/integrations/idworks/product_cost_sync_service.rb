module Integrations
  module Idworks
    # Pulls real cost per SKU from idworks (GET /sku) and applies it onto
    # matching Products — mirrors ProductSyncService's shape (adapter
    # build/authenticate, per-item error collection, IntegrationSyncLog),
    # but idworks is the source of truth for cost, not a sales channel's
    # catalog, so this only ever touches Product, never
    # ChannelProductListing.
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
          return Result.new(outcome: :skipped, synced_count: 0, error_message: nil, metadata: { reason: "cost não está configurado para idworks" })
        end

        log     = start_log
        adapter = IdworksAdapter.new(integration.credentials)
        adapter.authenticate

        synced_count, item_errors = sync_all(adapter)

        integration.update!(status: "connected", last_synced_at: Time.current)
        finish_log(log, status: item_errors.empty? ? "success" : "error", synced_count:, errors: item_errors)

        Result.new(
          outcome: item_errors.empty? ? :success : :error,
          synced_count: synced_count,
          error_message: item_errors.first&.fetch(:message, nil),
          metadata: { errors: item_errors }
        )
      rescue AuthenticationError => e
        integration.update!(status: "error")
        finish_log(log, status: "error", synced_count: 0, errors: [ { message: e.message } ])
        Result.new(outcome: :error, synced_count: 0, error_message: e.message, metadata: {})
      rescue RateLimitError => e
        finish_log(log, status: "error", synced_count: 0, errors: [ { message: "rate_limited: #{e.message}" } ])
        Result.new(outcome: :error, synced_count: 0, error_message: e.message, metadata: { retry_after: e.retry_after })
      rescue ApiError => e
        integration.update!(status: "error")
        finish_log(log, status: "error", synced_count: 0, errors: [ { message: e.message } ])
        Result.new(outcome: :error, synced_count: 0, error_message: e.message, metadata: {})
      end

      private

      attr_reader :integration, :tenant

      def sync_cost?
        DataSourceConfig.source_for(tenant, "cost") == "idworks"
      end

      def sync_all(adapter)
        synced_count = 0
        item_errors  = []

        adapter.fetch_products.each do |raw|
          if raw[:sku].blank?
            item_errors << { sku: nil, message: "sem SKU — ignorado" }
            next
          end

          applied = apply_to_product(raw)
          synced_count += 1 if applied
        rescue => e
          item_errors << { sku: raw[:sku], message: e.message }
        end

        [ synced_count, item_errors ]
      end

      def apply_to_product(raw)
        product = tenant.products.find_by(sku: raw[:sku])
        return false unless product

        cost = raw[:cost_last_purchase].presence || raw[:cost_average].presence
        return false if cost.blank?

        product.update!(cost_price: cost)
        true
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

      def finish_log(log, status:, synced_count:, errors:)
        log.update!(
          status: status,
          finished_at: Time.current,
          duration_ms: ((Time.current - log.started_at) * 1000).round,
          error_message: errors.first&.fetch(:message, nil),
          metadata: log.metadata.merge(synced_count: synced_count, error_count: errors.size, errors: errors.first(10))
        )
      end
    end
  end
end
