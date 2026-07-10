module Integrations
  module Idworks
    # Pulls real cost/tax_rate per SKU from idworks and applies them onto
    # matching Products — mirrors ProductSyncService's shape (adapter
    # build/authenticate, per-item error collection, IntegrationSyncLog),
    # but idworks is the source of truth for cost/tax, not a sales channel's
    # catalog, so this only ever touches Product, never
    # ChannelProductListing.
    #
    # Only applies when DataSourceConfig has "cost" and/or "tax" pointed at
    # "idworks" for this tenant — a tenant that's repointed either data_type
    # elsewhere shouldn't have idworks silently overwrite it.
    class ProductCostSyncService
      Result = Struct.new(:outcome, :synced_count, :error_message, :metadata, keyword_init: true) do
        def success? = outcome == :success
        def error?   = outcome == :error
      end

      def self.call(integration)
        new(integration).call
      end

      def initialize(integration)
        @integration = integration
        @tenant      = integration.tenant
      end

      def call
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

      def sync_tax?
        DataSourceConfig.source_for(tenant, "tax") == "idworks"
      end

      def sync_all(adapter)
        synced_count = 0
        item_errors  = []

        adapter.fetch_products_with_cost.each do |raw|
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
        return false unless sync_cost? || sync_tax?

        product = tenant.products.find_by(sku: raw[:sku])
        return false unless product

        product.cost_price = raw[:cost] if sync_cost? && raw[:cost].present?
        product.tax_rate   = raw[:tax_rate] if sync_tax? && raw[:tax_rate].present?
        product.save!
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
