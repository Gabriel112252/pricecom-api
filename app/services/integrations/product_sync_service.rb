module Integrations
  # Orchestrates a full product sync for one concrete ChannelCredential.
  # Multiple credentials may now exist for the same provider, so every
  # synced listing is tied back to the exact store connection that produced it.
  class ProductSyncService
    ADAPTERS = {
      "yampi"        => YampiAdapter,
      "shopify"      => ShopifyAdapter,
      "tiktok"       => TiktokAdapter,
      "mercadolivre" => MercadoLivreAdapter,
      "shopee"       => ShopeeAdapter
    }.freeze

    Result = Struct.new(:outcome, :synced_count, :error_message, :metadata, keyword_init: true) do
      def success? = outcome == :success
      def error?   = outcome == :error
      def skipped? = outcome == :skipped
    end

    def self.call(channel_credential)
      new(channel_credential).call
    end

    def self.adapter_for(channel_credential)
      klass = ADAPTERS.fetch(channel_credential.channel) do
        raise ArgumentError, "no adapter registered for channel #{channel_credential.channel}"
      end
      klass.new(channel_credential.credentials)
    end

    def initialize(channel_credential)
      @channel_credential = channel_credential
      @tenant = channel_credential.tenant
    end

    def call
      if channel_credential.consumidor_pedido?
        return Result.new(
          outcome: :skipped,
          synced_count: 0,
          error_message: nil,
          metadata: { reason: "role=consumidor_pedido — catalog owned by stock_source_channel" }
        )
      end

      log = start_log
      adapter = build_adapter

      adapter.authenticate
      synced_count, item_errors = sync_all(adapter)

      channel_credential.update!(status: "active", last_synced_at: Time.current)
      finish_log(log, status: item_errors.empty? ? "success" : "error", synced_count:, errors: item_errors)

      Result.new(
        outcome: item_errors.empty? ? :success : :error,
        synced_count: synced_count,
        error_message: item_errors.first&.fetch(:message, nil),
        metadata: { errors: item_errors }
      )
    rescue AuthenticationError => e
      channel_credential.update!(status: "error")
      finish_log(log, status: "error", synced_count: 0, errors: [ { message: e.message } ])
      Result.new(outcome: :error, synced_count: 0, error_message: e.message, metadata: {})
    rescue RateLimitError => e
      finish_log(log, status: "error", synced_count: 0, errors: [ { message: "rate_limited: #{e.message}" } ])
      Result.new(outcome: :error, synced_count: 0, error_message: e.message, metadata: { retry_after: e.retry_after })
    rescue ApiError => e
      channel_credential.update!(status: "error")
      finish_log(log, status: "error", synced_count: 0, errors: [ { message: e.message } ])
      Result.new(outcome: :error, synced_count: 0, error_message: e.message, metadata: {})
    end

    private

    attr_reader :channel_credential, :tenant

    def build_adapter
      self.class.adapter_for(channel_credential)
    end

    def sync_all(adapter)
      synced_count = 0
      item_errors = []

      adapter.fetch_products.each do |raw|
        normalized = adapter.normalize_product(raw)

        if normalized[:external_sku].blank?
          item_errors << { external_id: normalized[:external_id], message: "sem SKU externo — ignorado" }
          next
        end

        upsert_listing(normalized)
        synced_count += 1
      rescue => e
        item_errors << { external_id: normalized&.dig(:external_id), message: e.message }
      end

      [ synced_count, item_errors ]
    end

    def upsert_listing(normalized)
      product = tenant.products.find_or_initialize_by(sku: normalized[:external_sku])
      if product.new_record?
        product.name = normalized[:name].presence || normalized[:external_sku]
        product.cost_price ||= 0
      end
      product.save!

      listing = ChannelProductListing.find_or_initialize_by(
        tenant: tenant,
        channel_credential: channel_credential,
        external_id: normalized[:external_id]
      )
      listing.channel                    = channel_credential.channel
      listing.product                    = product
      listing.external_sku               = normalized[:external_sku]
      listing.stock_qty                  = normalized[:stock_qty]
      listing.price                      = normalized[:price]
      listing.raw_payload                = normalized[:raw]
      listing.synced_at                  = Time.current
      listing.external_inventory_item_id = normalized[:external_inventory_item_id]
      listing.external_product_id        = normalized[:external_product_id]
      listing.remote_status              = normalized[:remote_status]
      listing.remote_status_reason       = normalized[:remote_status_reason]
      listing.remote_status_metadata     = normalized[:remote_status_metadata] || {}
      listing.remote_status_synced_at    = Time.current
      listing.selling_status             = normalized[:selling_status] || "unknown"
      listing.selling_enabled            = normalized[:selling_enabled] || false
      listing.replenishment_eligible     = normalized[:replenishment_eligible] || false

      stock_qty_changed = listing.will_save_change_to_stock_qty?
      previous_stock_qty = listing.stock_qty_was if stock_qty_changed
      listing.save!
      record_channel_movement(listing, previous_stock_qty) if stock_qty_changed

      evaluate_stock_alert(listing)
    end

    def record_channel_movement(listing, previous_stock_qty)
      StockMovement.record!(
        tenant: tenant,
        product: listing.product,
        channel: listing.channel,
        kind: "sync",
        previous_qty: previous_stock_qty || 0,
        new_qty: listing.stock_qty,
        source: "channel_sync"
      )
    rescue => e
      Rails.logger.error("[StockMovement] channel sync log failed for listing=#{listing.id}: #{e.message}")
    end

    def evaluate_stock_alert(listing)
      StockAlerts::EvaluationService.call(listing.product)
    rescue => e
      Rails.logger.error("[StockAlert] evaluation failed for listing=#{listing.id}: #{e.message}")
    end

    def start_log
      IntegrationSyncLog.create!(
        tenant: tenant,
        channel_credential: channel_credential,
        direction: "inbound",
        action: "product_sync",
        status: "pending",
        started_at: Time.current,
        metadata: {
          channel: channel_credential.channel,
          channel_credential_id: channel_credential.id,
          connection_name: channel_credential.display_name
        }
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
