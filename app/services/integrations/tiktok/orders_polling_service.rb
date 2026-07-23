module Integrations
  module Tiktok
    # Polls TikTok Shop orders for one ChannelCredential, mirroring
    # Integrations::Yampi::OrdersPollingService: 30-day backfill on the
    # first run (orders_sync_cursor_at blank), incremental window with
    # overlap afterwards, guarded by a per-credential Redis lock and
    # recorded in IntegrationSyncLog.
    #
    # Unlike Yampi (whose API only filters by creation date), TikTok's
    # Get Order List supports update_time_ge/lt, so incremental runs filter
    # by update time — catching both new orders and status transitions
    # (paid → shipped → cancelled) without a created-at lookback window.
    # Re-processing an unchanged order is safe: UpsertOrder is idempotent.
    class OrdersPollingService
      BACKFILL_DAYS = 30
      INCREMENTAL_OVERLAP = 10.minutes
      PAGE_SIZE = Integrations::TiktokAdapter::ORDERS_PAGE_SIZE

      PollingEvent = Struct.new(:tenant, :payload, :event_type, :integration, keyword_init: true)

      Result = Struct.new(:outcome, :error_message, :retry_after, :metadata, keyword_init: true) do
        def success? = outcome == :success
        def error? = outcome == :error
        def skipped? = outcome == :skipped
        def rate_limited? = outcome == :rate_limited
      end

      def self.call(channel_credential, trigger: "scheduled")
        new(channel_credential, trigger: trigger).call
      end

      def initialize(channel_credential, trigger: "scheduled")
        @channel_credential = channel_credential
        @tenant = channel_credential.tenant
        @trigger = trigger
        @integration = tenant.integrations.active.find_by(provider: "tiktok")
        @adapter = Integrations::TiktokAdapter.new(channel_credential.credentials)
        @lock = Integrations::OrdersPollingLock.new(channel_credential)
        @started_at = Time.current
        @cursor_to = @started_at.utc
        @previous_cursor_at = channel_credential.orders_sync_cursor_at&.utc
        @sync_mode = previous_cursor_at.present? ? "incremental" : "backfill"
        @cursor_from = sync_mode == "incremental" ? previous_cursor_at - INCREMENTAL_OVERLAP : cursor_to - BACKFILL_DAYS.days
        @max_seen_cursor_at = nil
        @seen_external_ids = Set.new
        initialize_counters
      end

      def call
        @log = start_log

        unless channel_credential.polling_enabled?
          finish_log(status: "skipped", error_message: "polling desabilitado")
          return result(:skipped, "polling desabilitado")
        end

        unless lock.acquire
          @lock_acquired = false
          finish_log(status: "skipped", error_message: "polling já em execução")
          return result(:skipped, "polling já em execução")
        end

        @lock_acquired = true
        Channel.ensure_for!(tenant, "tiktok")
        fetch_and_process_pages
        enqueue_pending_financial_sync if created_count.positive? || updated_count.positive?

        if error_count.positive?
          finish_log(status: "error", error_message: item_errors.first&.fetch(:message, nil))
          return result(:error, item_errors.first&.fetch(:message, nil))
        end

        @new_cursor_at = next_cursor_at
        channel_credential.update!(orders_sync_cursor_at: @new_cursor_at, last_synced_at: Time.current, status: "active")
        finish_log(status: "success")
        result(:success, nil)
      rescue Integrations::AuthenticationError => e
        channel_credential.update!(status: "error")
        finish_log(status: "error", error_message: e.message)
        result(:error, e.message)
      rescue Integrations::RateLimitError => e
        @rate_limited = true
        @retry_after = e.retry_after || 60
        finish_log(status: "error", error_message: "rate_limited: #{e.message}")
        result(:rate_limited, e.message, retry_after: retry_after)
      rescue Integrations::ApiError => e
        finish_log(status: "error", error_message: e.message)
        result(:error, e.message)
      rescue => e
        finish_log(status: "error", error_message: e.message)
        result(:error, e.message)
      ensure
        lock.release if lock_acquired
      end

      private

      attr_reader :channel_credential, :tenant, :trigger, :integration, :adapter, :lock,
        :started_at, :cursor_to, :previous_cursor_at, :sync_mode, :cursor_from, :seen_external_ids,
        :log, :retry_after

      def initialize_counters
        @pages_fetched = 0
        @api_records_received = 0
        @created_count = 0
        @updated_count = 0
        @ignored_count = 0
        @error_count = 0
        @rate_limited = false
        @retry_after = nil
        @lock_acquired = nil
        @new_cursor_at = nil
        @item_errors = []
        @ignored_examples = []
        @processed_examples = []
      end

      def fetch_and_process_pages
        page_token = nil

        loop do
          data = adapter.fetch_orders_page(
            filters: time_filters,
            page_token: page_token,
            page_size: PAGE_SIZE,
            sort_field: cursor_source_field
          )

          @pages_fetched += 1
          orders = data["orders"] || []
          process_page(orders)
          lock.renew

          page_token = data["next_page_token"]
          break if orders.empty? || page_token.blank?
        end
      end

      # Backfill sweeps by creation time; incremental sweeps by update time
      # so status transitions on older orders are also picked up. Bounds are
      # Unix timestamps; *_lt is exclusive (doc: Get Order List 202309).
      def time_filters
        if sync_mode == "incremental"
          { update_time_ge: cursor_from.to_i, update_time_lt: cursor_to.to_i }
        else
          { create_time_ge: cursor_from.to_i, create_time_lt: cursor_to.to_i }
        end
      end

      def cursor_source_field
        sync_mode == "incremental" ? "update_time" : "create_time"
      end

      def process_page(raw_orders)
        @api_records_received += raw_orders.size

        raw_orders.each do |raw_order|
          observe_cursor_timestamp(cursor_timestamp_for(raw_order))
          process_order(raw_order)
        end
      end

      def process_order(raw_order)
        external_id = raw_order["id"].to_s

        if external_id.blank?
          record_ignored(nil, "sem identificador externo")
          return
        end

        if seen_external_ids.include?(external_id)
          record_ignored(external_id, "duplicado na mesma execução")
          return
        end
        seen_external_ids << external_id

        existing_order = find_existing_tiktok_order(external_id)
        event = PollingEvent.new(tenant: tenant, payload: raw_order, event_type: "order.polling", integration: integration)
        result = Integrations::Processors::TiktokOrderProcessor.call(event)

        if result.outcome == :success
          if existing_order
            @updated_count += 1
            record_processed(external_id, "updated")
          else
            @created_count += 1
            record_processed(external_id, "created")
          end
        elsif result.outcome == :skipped
          record_ignored(external_id, result.error_message || "ignorado pelo processor")
        else
          @error_count += 1
          item_errors << { external_id: external_id, message: result.error_message || "erro desconhecido" }
          record_processed(external_id, "error")
        end
      rescue => e
        @error_count += 1
        item_errors << { external_id: raw_order["id"]&.to_s, message: e.message }
        record_processed(raw_order["id"]&.to_s, "error")
      end

      def cursor_timestamp_for(raw_order)
        value = sync_mode == "incremental" ? raw_order["update_time"] : raw_order["create_time"]
        return nil if value.blank?

        Time.zone.at(value.to_i).utc
      rescue TypeError
        nil
      end

      def observe_cursor_timestamp(timestamp)
        return unless timestamp

        @max_seen_cursor_at = timestamp if @max_seen_cursor_at.nil? || timestamp > @max_seen_cursor_at
      end

      def next_cursor_at
        if @max_seen_cursor_at
          observed_cursor_at = [ @max_seen_cursor_at, cursor_to ].min
          return [ observed_cursor_at, previous_cursor_at ].compact.max
        end

        return previous_cursor_at if previous_cursor_at.present?

        cursor_to
      end

      def find_existing_tiktok_order(external_id)
        tenant.orders.joins(:channel).find_by(external_id: external_id, channels: { platform: "tiktok" })
      end

      def record_ignored(external_id, reason)
        @ignored_count += 1
        ignored_examples << { external_id: external_id, reason: reason } if ignored_examples.size < 10
        record_processed(external_id, "ignored")
      end

      def record_processed(external_id, outcome)
        return if processed_examples.size >= 20

        processed_examples << { external_id: external_id, outcome: outcome }
      end

      def enqueue_pending_financial_sync
        Integrations::Tiktok::PendingFinancialSyncJob.perform_later(
          channel_credential.id,
          batch_size: Integrations::Tiktok::PendingFinancialSyncService::DEFAULT_BATCH_SIZE
        )
      rescue => e
        Rails.logger.error("[Integrations::Tiktok::OrdersPollingService] financial enqueue failed: #{e.message}")
      end

      def start_log
        IntegrationSyncLog.create!(
          tenant: tenant,
          integration: integration,
          direction: "inbound",
          action: "tiktok_order_polling",
          status: "pending",
          started_at: started_at,
          metadata: base_metadata
        )
      end

      def finish_log(status:, error_message: nil)
        return unless log

        finished_at = Time.current
        duration_ms = ((finished_at - started_at) * 1000).round
        log.update!(
          status: status,
          finished_at: finished_at,
          duration_ms: duration_ms,
          error_message: error_message,
          metadata: log.metadata.merge(count_metadata).merge(duration_ms: duration_ms)
        )
      end

      def base_metadata
        {
          trigger: trigger,
          channel: "tiktok",
          channel_credential_id: channel_credential.id,
          sync_mode: sync_mode,
          window_from: cursor_from.iso8601,
          window_to: cursor_to.iso8601,
          cursor_source_field: cursor_source_field,
          previous_cursor_at: previous_cursor_at&.iso8601
        }
      end

      def count_metadata
        {
          new_cursor_at: @new_cursor_at&.iso8601,
          max_seen_cursor_at: @max_seen_cursor_at&.iso8601,
          pages_fetched: @pages_fetched,
          api_records_received: @api_records_received,
          created_count: @created_count,
          updated_count: @updated_count,
          ignored_count: @ignored_count,
          error_count: @error_count,
          rate_limited: @rate_limited,
          retry_after: retry_after,
          lock_acquired: @lock_acquired,
          processed_examples: processed_examples,
          ignored_examples: ignored_examples,
          errors: item_errors.first(10)
        }
      end

      def result(outcome, error_message, retry_after: nil)
        Result.new(outcome: outcome, error_message: error_message, retry_after: retry_after, metadata: count_metadata)
      end

      def error_count = @error_count
      def created_count = @created_count
      def updated_count = @updated_count
      def item_errors = @item_errors
      def ignored_examples = @ignored_examples
      def processed_examples = @processed_examples
      def lock_acquired = @lock_acquired
    end
  end
end
