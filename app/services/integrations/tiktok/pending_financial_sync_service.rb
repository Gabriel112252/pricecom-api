module Integrations
  module Tiktok
    class PendingFinancialSyncService
      ACTION = "tiktok_pending_financial_sync".freeze
      DEFAULT_BATCH_SIZE = Integer(ENV.fetch("TIKTOK_PENDING_FINANCIAL_BATCH_SIZE", "100"))
      DEFAULT_WINDOW_DAYS = Integer(ENV.fetch("TIKTOK_PENDING_FINANCIAL_WINDOW_DAYS", "90"))
      RECENT_DAYS = 14
      RECENT_BASE_DELAY = 15.minutes
      OLD_BASE_DELAY = 2.hours
      MAX_DELAY = 24.hours
      ELIGIBLE_STATUSES = %w[
        on_hold awaiting_shipment partially_shipping awaiting_collection
        in_transit shipped delivered completed paid processing
      ].freeze

      Result = Struct.new(:outcome, :error_message, :metadata, keyword_init: true) do
        def success? = outcome == :success
        def error? = outcome == :error
        def skipped? = outcome == :skipped
        def rate_limited? = outcome == :rate_limited
      end

      def self.call(channel_credential, order_ids: nil, batch_size: DEFAULT_BATCH_SIZE,
        window_days: DEFAULT_WINDOW_DAYS, run_id: nil)
        new(
          channel_credential,
          order_ids: order_ids,
          batch_size: batch_size,
          window_days: window_days,
          run_id: run_id
        ).call
      end

      def initialize(channel_credential, order_ids:, batch_size:, window_days:, run_id:)
        @channel_credential = channel_credential
        @tenant = channel_credential.tenant
        @order_ids = Array(order_ids).map(&:to_i).select(&:positive?)
        @batch_size = [ batch_size.to_i, 1 ].max
        @window_days = [ window_days.to_i, 1 ].max
        @run_id = run_id.to_s.presence || SecureRandom.uuid
        @lock = FinancialSyncLock.new(channel_credential)
        @adapter = Integrations::TiktokAdapter.new(channel_credential.credentials)
        initialize_counters
      end

      def call
        @channel = tenant.channels.find_by(platform: "tiktok")
        return result(:skipped, "canal tiktok não encontrado") unless channel
        return result(:skipped, "credencial TikTok não está ativa") unless channel_credential.status == "active"

        unless lock.acquire
          raise FinancialSyncLock::LockBusyError,
            "sincronização financeira pendente TikTok já está em execução"
        end

        @lock_acquired = true
        @log = start_log
        pending_orders.find_each(batch_size: batch_size) do |order|
          process_order(order)
          persist_checkpoint(order)
          break if processed_count >= batch_size || authentication_failed?
        end
        finish_log(error_count.positive? ? "error" : "success")
        result(error_count.positive? ? :error : :success, log.error_message)
      rescue Integrations::AuthenticationError => e
        finish_log("error", e.message)
        result(:error, e.message)
      rescue Integrations::RateLimitError
        finish_log("pending", "rate limited")
        raise
      rescue FinancialSyncLock::LockLostError
        finish_log("error", "lock perdido")
        raise
      ensure
        lock.release if lock_acquired
      end

      private

      attr_reader :channel_credential, :tenant, :channel, :lock, :adapter,
        :batch_size, :window_days, :log, :run_id

      def initialize_counters
        @processed_count = 0
        @synced_count = 0
        @pending_count = 0
        @error_count = 0
        @auth_error_count = 0
        @last_order_id = nil
        @next_retry_at = nil
        @error_samples = []
        @lock_acquired = false
        @authentication_failed = false
      end

      def pending_orders
        scope = channel.orders
          .where(financial_synced_at: nil)
          .where("LOWER(COALESCE(orders.status, '')) IN (?)", ELIGIBLE_STATUSES)
          .where("COALESCE(orders.ordered_at, orders.created_at) >= ?", window_days.days.ago)
          .order(:id)

        scope = scope.where(id: order_ids) if order_ids.present?
        if tracking_column?(:financial_next_attempt_at)
          scope = scope.where("orders.financial_next_attempt_at IS NULL OR orders.financial_next_attempt_at <= ?", Time.current)
        end
        if tracking_column?(:financial_pending_reason)
          scope = scope.where.not(financial_pending_reason: "authentication_invalid")
        end

        if resume_order_id.present? && order_ids.empty?
          scope = scope.where("orders.id > ?", resume_order_id)
        end
        scope.limit(batch_size)
      end

      def process_order(order)
        @last_order_id = order.id
        mark_attempt(order)

        OrderFinancialSyncService.call(
          order: order,
          channel_credential: channel_credential,
          adapter: adapter
        )
        @processed_count += 1
        @synced_count += 1
        clear_pending(order)
      rescue OrderFinancialSyncService::PendingStatementError => e
        @processed_count += 1
        @pending_count += 1
        schedule_retry(order, "not_settled", e.message)
      rescue Integrations::AuthenticationError => e
        @processed_count += 1
        @auth_error_count += 1
        @error_count += 1
        channel_credential.update!(status: "error")
        @authentication_failed = true
        set_pending_state(order, reason: "authentication_invalid", next_at: nil)
        record_error(order, e.message)
      rescue Integrations::RateLimitError => e
        next_at = Time.current + [ e.retry_after.to_f.to_i, 60 ].max
        @next_retry_at = next_at
        set_pending_state(
          order,
          reason: "rate_limited",
          next_at: next_at
        )
        @pending_count += 1
        raise
      rescue Faraday::Error, Integrations::ApiError => e
        @processed_count += 1
        @error_count += 1
        schedule_retry(order, "temporary_error", e.message)
      rescue => e
        @processed_count += 1
        @error_count += 1
        schedule_retry(order, "error", e.message)
      end

      def mark_attempt(order)
        return unless tracking_column?(:financial_sync_attempts)

        order.with_lock do
          order.update_columns(
            financial_sync_attempts: order.financial_sync_attempts.to_i + 1,
            financial_last_attempt_at: Time.current,
            financial_next_attempt_at: nil,
            financial_pending_reason: "in_progress"
          )
        end
      end

      def clear_pending(order)
        return unless tracking_column?(:financial_pending_reason)

        order.update_columns(financial_pending_reason: nil, financial_next_attempt_at: nil)
      end

      def schedule_retry(order, reason, _message)
        @pending_count += 1
        next_at = Time.current + backoff_for(order)
        @next_retry_at = next_at if @next_retry_at.nil? || next_at < @next_retry_at
        set_pending_state(order, reason: reason, next_at: next_at)
      end

      def set_pending_state(order, reason:, next_at:)
        return unless tracking_column?(:financial_pending_reason)

        order.update_columns(
          financial_pending_reason: reason,
          financial_next_attempt_at: next_at
        )
      end

      def backoff_for(order)
        attempts = order.respond_to?(:financial_sync_attempts) ? order.financial_sync_attempts.to_i : 1
        base = recent_order?(order) ? RECENT_BASE_DELAY : OLD_BASE_DELAY
        [ base * (2**[ attempts - 1, 6 ].min), MAX_DELAY ].min
      end

      def recent_order?(order)
        reference = order.ordered_at || order.created_at
        reference.present? && reference >= RECENT_DAYS.days.ago
      end

      def start_log
        IntegrationSyncLog.create!(
          tenant: tenant,
          direction: "inbound",
          action: ACTION,
          status: "pending",
          started_at: Time.current,
          metadata: metadata_snapshot
        )
      end

      def persist_checkpoint(order)
        return unless log

        log.update!(metadata: (log.metadata || {}).merge(metadata_snapshot(order)))
      end

      def finish_log(status, error_message = nil)
        return unless log

        finished_at = status == "pending" ? nil : Time.current
        log.update!(
          status: status,
          finished_at: finished_at,
          error_message: error_message,
          metadata: (log.metadata || {}).merge(metadata_snapshot)
        )
      end

      def metadata_snapshot(order = nil)
        {
          "channel_credential_id" => channel_credential.id,
          "run_id" => run_id,
          "batch_size" => batch_size,
          "window_days" => window_days,
          "processed_count" => processed_count,
          "synced_count" => synced_count,
          "pending_count" => pending_count,
          "error_count" => error_count,
          "auth_error_count" => auth_error_count,
          "last_order_id" => order&.id || last_order_id,
          "next_retry_at" => next_retry_at,
          "error_samples" => error_samples
        }
      end

      def record_error(order, message)
        return if error_samples.size >= 20

        error_samples << { order_id: order.id, external_id: order.external_id, message: message }
      end

      def resume_order_id
        return if order_ids.present?

        IntegrationSyncLog
          .where(tenant: tenant, action: ACTION, status: "pending")
          .order(created_at: :desc)
          .find do |candidate|
            candidate.metadata.to_h["channel_credential_id"].to_s == channel_credential.id.to_s
          end&.metadata.to_h&.fetch("last_order_id", nil).to_i
      end

      def tracking_column?(name)
        Order.column_names.include?(name.to_s)
      end

      def processed_count = @processed_count
      def synced_count = @synced_count
      def pending_count = @pending_count
      def error_count = @error_count
      def auth_error_count = @auth_error_count
      def last_order_id = @last_order_id
      def error_samples = @error_samples
      def next_retry_at = @next_retry_at
      def order_ids = @order_ids
      def lock_acquired = @lock_acquired
      def authentication_failed? = @authentication_failed
      def result(outcome, error_message = nil)
        Result.new(outcome: outcome, error_message: error_message, metadata: metadata_snapshot)
      end
    end
  end
end
