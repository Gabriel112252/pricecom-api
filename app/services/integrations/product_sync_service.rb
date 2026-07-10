module Integrations
  # Orchestrates a full product sync for one ChannelCredential: builds the
  # right adapter, authenticates, fetches products, and upserts Product +
  # ChannelProductListing per SKU by external_sku. The adapter interface is
  # identical across channels, so this class never branches on `channel`
  # itself.
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

    def initialize(channel_credential)
      @channel_credential = channel_credential
      @tenant = channel_credential.tenant
    end

    # Channels whose role is "consumidor_pedido" never own real stock —
    # they place orders against another channel's inventory (e.g. Yampi
    # checkout backed by Shopify). Syncing their catalog would create a
    # duplicate, disconnected ChannelProductListing that nothing ever
    # deducts from, so we skip them entirely rather than sync-then-ignore.
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
      klass = ADAPTERS.fetch(channel_credential.channel) do
        raise ArgumentError, "no adapter registered for channel #{channel_credential.channel}"
      end
      klass.new(channel_credential.credentials)
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

    # Matches by external_sku first: an existing local Product with that
    # SKU is reused, otherwise a new Product is created automatically.
    def upsert_listing(normalized)
      product = tenant.products.find_or_initialize_by(sku: normalized[:external_sku])
      if product.new_record?
        product.name = normalized[:name].presence || normalized[:external_sku]
        product.cost_price ||= 0
      end
      product.save!

      listing = ChannelProductListing.find_or_initialize_by(
        tenant: tenant,
        channel: channel_credential.channel,
        external_id: normalized[:external_id]
      )
      listing.product      = product
      listing.external_sku = normalized[:external_sku]
      listing.stock_qty    = normalized[:stock_qty]
      listing.price        = normalized[:price]
      listing.raw_payload  = normalized[:raw]
      listing.synced_at    = Time.current
      listing.save!
    end

    def start_log
      IntegrationSyncLog.create!(
        tenant: tenant,
        direction: "inbound",
        action: "product_sync",
        status: "pending",
        started_at: Time.current,
        metadata: { channel: channel_credential.channel, channel_credential_id: channel_credential.id }
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
