module Integrations
  module Tiktok
    # Re-fetches Get Order Detail for every already-synced TikTok order and
    # reprocesses it through the normal TiktokOrderProcessor pipeline (same
    # one OrdersPollingService uses), so orders imported before the
    # 2026-07-21 fix to TiktokOrderNormalizer#extract_discount get their
    # discount/seller_discount/platform_discount/margin recalculated
    # correctly. There is no cheap "only orders affected" filter: the bug
    # left seller_discount/platform_discount at their post-migration default
    # of 0 exactly like a never-synced order would, so every TikTok order
    # has to be re-fetched and reprocessed to know which ones actually had
    # a platform_discount.
    #
    # Reusing TiktokOrderProcessor (UpsertOrder → stock deduction, cart
    # conversion, freight-margin sync, etc.) instead of writing a narrower
    # "just update discount columns" path is deliberate: every one of those
    # side effects is already idempotent for a re-synced order (stock
    # deduction gates on Order#stock_deducted_at, cart conversion gates on
    # cart.status, freight-margin sync recomputes the day's aggregate) —
    # this is the exact mechanism ShippingFeeAuditBackfillService already
    # uses for the same class of "re-sync old TikTok orders" problem.
    #
    # Progress is tracked on an IntegrationSyncLog (action:
    # "tiktok_discount_backfill") instead of a dedicated table — the same
    # generic mechanism every other TikTok sync/backfill in this codebase
    # already uses. A "pending" log from a previous run is resumed from its
    # last_order_id instead of starting over, so a killed Sidekiq job (this
    # can run against 100k+ orders) doesn't have to restart from zero.
    class DiscountBackfillService
      BATCH_SIZE          = Integrations::TiktokAdapter::ORDER_DETAIL_MAX_IDS
      MAX_ERROR_SAMPLES    = 20
      ACTION               = "tiktok_discount_backfill"
      DEFAULT_BATCH_SLEEP  = 0.5

      BackfillEvent = Struct.new(:tenant, :payload, :event_type, :integration, keyword_init: true)
      Result = Struct.new(:outcome, :error_message, :metadata, keyword_init: true) do
        def success? = outcome == :success
        def skipped? = outcome == :skipped
      end

      def self.call(channel_credential, batch_sleep: DEFAULT_BATCH_SLEEP)
        new(channel_credential, batch_sleep: batch_sleep).call
      end

      def initialize(channel_credential, batch_sleep: DEFAULT_BATCH_SLEEP)
        @channel_credential = channel_credential
        @tenant             = channel_credential.tenant
        @integration        = tenant.integrations.active.find_by(provider: "tiktok")
        @adapter            = Integrations::TiktokAdapter.new(channel_credential.credentials)
        @batch_sleep        = batch_sleep.to_f
      end

      def call
        @channel = tenant.channels.find_by(platform: "tiktok")
        return Result.new(outcome: :skipped, error_message: "canal tiktok nao encontrado", metadata: {}) unless channel

        resume_or_start_log
        fetch_and_process_batches
        finish_log(status: @error_count.positive? ? "error" : "success")
        Result.new(outcome: @error_count.positive? ? :error : :success, error_message: nil, metadata: metadata_snapshot)
      rescue Integrations::AuthenticationError, Integrations::ApiError, Integrations::RateLimitError => e
        channel_credential.update!(status: "error") if e.is_a?(Integrations::AuthenticationError)
        finish_log(status: "error", error_message: e.message)
        Result.new(outcome: :error, error_message: e.message, metadata: metadata_snapshot)
      end

      private

      attr_reader :channel_credential, :tenant, :integration, :adapter, :batch_sleep, :channel, :log

      def resume_or_start_log
        @log = IntegrationSyncLog
          .where(tenant: tenant, integration: integration, action: ACTION, status: "pending")
          .order(created_at: :desc)
          .first

        if log
          meta              = log.metadata
          @processed_count  = meta["processed_count"].to_i
          @error_count      = meta["error_count"].to_i
          @error_samples    = meta["error_samples"] || []
          @resume_from_id   = meta["last_order_id"]
          @total_orders     = meta["total_orders"].to_i
        else
          @processed_count  = 0
          @error_count      = 0
          @error_samples    = []
          @resume_from_id   = nil
          @total_orders     = channel.orders.count
          @log = IntegrationSyncLog.create!(
            tenant: tenant, integration: integration, direction: "inbound", action: ACTION,
            status: "pending", started_at: Time.current,
            metadata: { channel_credential_id: channel_credential.id, total_orders: @total_orders }
          )
        end
      end

      def fetch_and_process_batches
        scope = channel.orders.order(:id)
        scope = scope.where("orders.id > ?", @resume_from_id) if @resume_from_id.present?

        scope.find_in_batches(batch_size: BATCH_SIZE) do |orders|
          process_batch(orders)
          persist_progress(last_order_id: orders.last.id)
          sleep(batch_sleep) if batch_sleep.positive?
        end
      end

      def process_batch(orders)
        details = adapter.fetch_order_details(orders.map(&:external_id))
        details_by_id = details.index_by { |raw| raw["id"].to_s }

        orders.each do |order|
          raw = details_by_id[order.external_id.to_s]
          unless raw
            record_error(order, "order detail not returned by TikTok")
            next
          end

          process_detail(order, raw)
        end
      end

      def process_detail(order, raw)
        processed = Integrations::Processors::TiktokOrderProcessor.call(
          BackfillEvent.new(tenant: tenant, payload: raw, event_type: "order.discount_backfill", integration: integration)
        )

        if processed.outcome == :success
          @processed_count += 1
        else
          record_error(order, processed.error_message || "erro desconhecido")
        end
      end

      def record_error(order, message)
        @error_count += 1
        return if @error_samples.size >= MAX_ERROR_SAMPLES

        @error_samples << "order_id=#{order.id} external_id=#{order.external_id}: #{message}"
      end

      def persist_progress(last_order_id:)
        @last_order_id = last_order_id
        log.update!(metadata: log.metadata.merge(metadata_snapshot))
      end

      def metadata_snapshot
        {
          channel_credential_id: channel_credential.id,
          total_orders:    @total_orders,
          processed_count: @processed_count,
          error_count:     @error_count,
          error_samples:   @error_samples,
          last_batch_at:   Time.current,
          last_order_id:   @last_order_id || log.metadata["last_order_id"]
        }
      end

      def finish_log(status:, error_message: nil)
        finished_at = Time.current
        log.update!(
          status:       status,
          finished_at:  finished_at,
          duration_ms:  log.started_at ? ((finished_at - log.started_at) * 1000).round : nil,
          error_message: error_message,
          metadata:     log.metadata.merge(metadata_snapshot)
        )
      end
    end
  end
end
