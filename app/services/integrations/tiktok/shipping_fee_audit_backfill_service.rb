module Integrations
  module Tiktok
    # Fetches Get Order Detail for already-imported TikTok orders whose
    # shipping audit fields are still blank. Older Get Order List imports may
    # have persisted payment.shipping_fee as Order#freight but not
    # payment.original_shipping_fee, leaving the freight-margin dashboard with
    # no TikTok real freight cost for those paid orders.
    class ShippingFeeAuditBackfillService
      DEFAULT_BATCH_SIZE = Integrations::TiktokAdapter::ORDER_DETAIL_MAX_IDS
      MAX_EXAMPLES = 10

      BackfillEvent = Struct.new(:tenant, :payload, :event_type, :integration, keyword_init: true)
      Result = Struct.new(:outcome, :error_message, :metadata, keyword_init: true) do
        def success? = outcome == :success
        def error? = outcome == :error
        def skipped? = outcome == :skipped
      end

      def self.call(channel_credential, limit: nil, batch_sleep: 0)
        new(channel_credential, limit: limit, batch_sleep: batch_sleep).call
      end

      def initialize(channel_credential, limit: nil, batch_sleep: 0)
        @channel_credential = channel_credential
        @tenant = channel_credential.tenant
        @integration = tenant.integrations.active.find_by(provider: "tiktok")
        @adapter = Integrations::TiktokAdapter.new(channel_credential.credentials)
        @limit = limit.to_i.positive? ? limit.to_i : nil
        @batch_sleep = batch_sleep.to_f.positive? ? batch_sleep.to_f : 0
        @started_at = Time.current
        reset_counts
      end

      def call
        @log = start_log
        @channel = tenant.channels.find_by(platform: "tiktok")

        unless channel
          finish_log(status: "skipped", error_message: "canal tiktok nao encontrado")
          return result(:skipped, "canal tiktok nao encontrado")
        end

        fetch_and_process_batches
        finish_log(status: errors.empty? ? "success" : "error", error_message: errors.first&.fetch(:message, nil))
        result(errors.empty? ? :success : :error, errors.first&.fetch(:message, nil))
      rescue Integrations::AuthenticationError, Integrations::ApiError, Integrations::RateLimitError => e
        channel_credential.update!(status: "error") if e.is_a?(Integrations::AuthenticationError)
        finish_log(status: "error", error_message: e.message)
        result(:error, e.message)
      rescue => e
        finish_log(status: "error", error_message: e.message)
        result(:error, e.message)
      end

      private

      attr_reader :channel_credential, :tenant, :integration, :adapter, :limit,
        :batch_sleep, :started_at, :log, :channel, :errors

      def reset_counts
        @eligible_count = 0
        @api_batches = 0
        @api_orders_received = 0
        @processed_count = 0
        @filled_count = 0
        @still_missing_count = 0
        @detail_missing_count = 0
        @errors = []
        @filled_examples = []
        @still_missing_examples = []
        @detail_missing_examples = []
      end

      def fetch_and_process_batches
        scope = eligible_orders
        @eligible_count = scope.count

        scope.find_in_batches(batch_size: DEFAULT_BATCH_SIZE) do |orders|
          process_batch(orders)
          sleep(batch_sleep) if batch_sleep.positive?
        end
      end

      def eligible_orders
        scope = channel.orders
          .sales
          .revenue_countable
          .where(original_shipping_fee: nil)
          .where.not(external_id: [ nil, "" ])
          .order(:ordered_at, :id)

        limit ? scope.limit(limit) : scope
      end

      def process_batch(orders)
        details = adapter.fetch_order_details(orders.map(&:external_id))
        @api_batches += 1
        @api_orders_received += details.size
        details_by_id = details.index_by { |raw| raw["id"].to_s }

        orders.each do |order|
          raw = details_by_id[order.external_id.to_s]
          unless raw
            record_detail_missing(order)
            next
          end

          process_detail(order, raw)
        end
      end

      def process_detail(order, raw)
        processed = Integrations::Processors::TiktokOrderProcessor.call(
          BackfillEvent.new(
            tenant: tenant,
            payload: raw,
            event_type: "order.shipping_fee_audit_backfill",
            integration: integration
          )
        )

        unless processed.outcome == :success
          record_error(order, processed.error_message || "erro desconhecido")
          return
        end

        @processed_count += 1
        if order.reload.original_shipping_fee.present?
          @filled_count += 1
          record_filled(order)
        else
          @still_missing_count += 1
          record_still_missing(order)
        end
      end

      def record_filled(order)
        return if @filled_examples.size >= MAX_EXAMPLES

        @filled_examples << {
          order_id: order.id,
          order_number: order.order_number,
          freight: order.freight.to_s,
          original_shipping_fee: order.original_shipping_fee.to_s
        }
      end

      def record_still_missing(order)
        return if @still_missing_examples.size >= MAX_EXAMPLES

        @still_missing_examples << {
          order_id: order.id,
          order_number: order.order_number
        }
      end

      def record_detail_missing(order)
        @detail_missing_count += 1
        return if @detail_missing_examples.size >= MAX_EXAMPLES

        @detail_missing_examples << {
          order_id: order.id,
          order_number: order.order_number,
          external_id: order.external_id
        }
      end

      def record_error(order, message)
        errors << {
          order_id: order.id,
          order_number: order.order_number,
          message: message
        }
      end

      def start_log
        IntegrationSyncLog.create!(
          tenant: tenant,
          integration: integration,
          direction: "inbound",
          action: "tiktok_shipping_fee_audit_backfill",
          status: "pending",
          started_at: started_at,
          metadata: base_metadata
        )
      end

      def finish_log(status:, error_message: nil)
        return unless log

        finished_at = Time.current
        log.update!(
          status: status,
          finished_at: finished_at,
          duration_ms: ((finished_at - started_at) * 1000).round,
          error_message: error_message,
          metadata: log.metadata.merge(count_metadata)
        )
      end

      def base_metadata
        {
          channel: "tiktok",
          channel_credential_id: channel_credential.id,
          source_endpoint: "order_detail",
          limit: limit,
          batch_sleep: batch_sleep
        }
      end

      def count_metadata
        {
          eligible_count: @eligible_count,
          api_batches: @api_batches,
          api_orders_received: @api_orders_received,
          processed_count: @processed_count,
          filled_count: @filled_count,
          still_missing_count: @still_missing_count,
          detail_missing_count: @detail_missing_count,
          filled_examples: @filled_examples,
          still_missing_examples: @still_missing_examples,
          detail_missing_examples: @detail_missing_examples,
          errors: errors.first(MAX_EXAMPLES)
        }
      end

      def result(outcome, error_message)
        Result.new(outcome: outcome, error_message: error_message, metadata: count_metadata)
      end
    end
  end
end
