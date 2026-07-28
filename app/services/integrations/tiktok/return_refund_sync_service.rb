module Integrations
  module Tiktok
    # Fetches TikTok Shop returns/refunds (Search Returns 202309 — see
    # TiktokAdapter#fetch_returns) and persists reason/status/amount onto the
    # matching local order via the same Integrations::Orders::UpsertRefund
    # shared by Yampi/Shopify/TikTok's statement-based refund sync
    # (StatementFinancialBackfillService#persist_refund_from_statement).
    #
    # Runs either scoped to a set of order_ids (targeted re-check) or over a
    # create_time window (scheduled sweep, see ReturnRefundSyncSchedulerJob).
    #
    # UpsertRefund keys order_refunds by the ORDER's own external_id (not the
    # return's own return_id) — same constraint every channel's refund flow
    # already lives with. If TikTok reports more than one return for the same
    # order within a run, only the last one processed survives; that's an
    # existing limitation of the shared upsert, not something new here.
    class ReturnRefundSyncService
      DEFAULT_WINDOW_DAYS = 7
      PAGE_SIZE = 50
      MAX_ERROR_SAMPLES = 10

      Result = Struct.new(:outcome, :error_message, :metadata, keyword_init: true) do
        def success? = outcome == :success
        def error? = outcome == :error
        def skipped? = outcome == :skipped
      end

      def self.call(channel_credential, order_ids: nil, window_days: DEFAULT_WINDOW_DAYS, trigger: "scheduled")
        new(channel_credential, order_ids: order_ids, window_days: window_days, trigger: trigger).call
      end

      def initialize(channel_credential, order_ids: nil, window_days: DEFAULT_WINDOW_DAYS, trigger: "scheduled")
        @channel_credential = channel_credential
        @tenant = channel_credential.tenant
        @order_ids = Array(order_ids).map(&:to_s).reject(&:blank?)
        @window_days = window_days.presence || DEFAULT_WINDOW_DAYS
        @trigger = trigger
        @adapter = Integrations::TiktokAdapter.new(channel_credential.credentials)
        @started_at = Time.current
        @returns_count = 0
        @matched_count = 0
        @missing_count = 0
        @synced_count = 0
        @error_count = 0
        @item_errors = []
      end

      def call
        @log = start_log

        @channel = tenant.channels.find_by(platform: "tiktok")
        unless channel
          finish_log(status: "skipped", error_message: "canal tiktok não encontrado")
          return result(:skipped, "canal tiktok não encontrado")
        end

        fetch_and_process_returns

        if error_count.positive?
          finish_log(status: "error", error_message: item_errors.first&.fetch(:message, nil))
          return result(:error, item_errors.first&.fetch(:message, nil))
        end

        finish_log(status: "success")
        result(:success, nil)
      rescue Integrations::AuthenticationError => e
        channel_credential.update!(status: "error")
        finish_log(status: "error", error_message: e.message)
        result(:error, e.message)
      rescue Integrations::RateLimitError => e
        finish_log(status: "error", error_message: "rate_limited: #{e.message}")
        raise
      end

      private

      attr_reader :channel_credential, :tenant, :order_ids, :window_days, :trigger, :adapter,
        :channel, :started_at, :log, :item_errors, :error_count

      def fetch_and_process_returns
        cursor = nil

        loop do
          page = adapter.fetch_returns(filters: filters, page_size: PAGE_SIZE, page_token: cursor)
          returns = Array(page["return_orders"])
          @returns_count += returns.size

          returns.each { |raw| process_return(raw) }

          cursor = page["next_page_token"].presence
          break if returns.empty? || cursor.blank?
        end
      end

      def filters
        return { order_ids: order_ids } if order_ids.any?

        {
          create_time_ge: window_days.to_i.days.ago.to_i,
          create_time_lt: Time.current.to_i
        }
      end

      def process_return(raw)
        normalized = Integrations::Normalizers::TiktokReturnRefundNormalizer.call(raw)
        return if normalized[:external_id].blank?

        order = channel.orders.find_by(external_id: normalized[:external_id])
        unless order
          @missing_count += 1
          return
        end

        @matched_count += 1
        upsert = Integrations::Orders::UpsertRefund.call(
          tenant:     tenant,
          provider:   "tiktok",
          normalized: normalized.merge(order_number: order.order_number)
        )

        if upsert.success?
          @synced_count += 1
        else
          record_error(normalized[:external_id], upsert.error_message)
        end
      rescue => e
        record_error(raw.is_a?(Hash) ? raw["order_id"] : nil, e.message)
      end

      def record_error(external_id, message)
        @error_count += 1
        return if item_errors.size >= MAX_ERROR_SAMPLES

        item_errors << { external_id: external_id&.to_s, message: message }
      end

      def start_log
        IntegrationSyncLog.create!(
          tenant:      tenant,
          direction:   "inbound",
          action:      "tiktok_return_refund_sync",
          status:      "pending",
          started_at:  started_at,
          metadata: {
            trigger:               trigger,
            channel_credential_id: channel_credential.id,
            order_ids:             order_ids,
            window_days:           window_days
          }
        )
      end

      def finish_log(status:, error_message: nil)
        return unless log

        finished_at = Time.current
        log.update!(
          status:        status,
          finished_at:   finished_at,
          duration_ms:   ((finished_at - started_at) * 1000).round,
          error_message: error_message,
          metadata:      log.metadata.merge(count_metadata)
        )
      end

      def count_metadata
        {
          returns_count: @returns_count,
          matched_count: @matched_count,
          missing_count: @missing_count,
          synced_count:  @synced_count,
          error_count:   error_count,
          errors:        item_errors
        }
      end

      def result(outcome, error_message)
        Result.new(outcome: outcome, error_message: error_message, metadata: count_metadata)
      end
    end
  end
end
