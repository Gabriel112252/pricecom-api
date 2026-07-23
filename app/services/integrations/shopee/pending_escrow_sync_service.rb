module Integrations
  module Shopee
    # Varre pedidos Shopee já ingeridos sem financeiro (financial_synced_at
    # nulo) e puxa o escrow de cada um — espelho enxuto do
    # Tiktok::PendingFinancialSyncService, reusando as mesmas colunas de
    # tracking do Order (financial_sync_attempts/_next_attempt_at/
    # _pending_reason, que são channel-agnósticas). Enfileirado pelo
    # OrdersPollingService após cada ingestão com criações/atualizações;
    # não tem cron próprio (mesma decisão do TikTok).
    class PendingEscrowSyncService
      ACTION = "shopee_pending_escrow_sync".freeze
      DEFAULT_BATCH_SIZE = Integer(ENV.fetch("SHOPEE_PENDING_ESCROW_BATCH_SIZE", "100"))
      DEFAULT_WINDOW_DAYS = Integer(ENV.fetch("SHOPEE_PENDING_ESCROW_WINDOW_DAYS", "90"))
      RECENT_DAYS = 14
      RECENT_BASE_DELAY = 30.minutes
      OLD_BASE_DELAY = 4.hours
      MAX_DELAY = 24.hours
      # Escrow só existe depois que o pedido anda: unpaid/cancelado ficam
      # fora; COMPLETED é quando a Shopee consolida o repasse, mas os
      # intermediários já podem ter order_income parcial — o
      # PendingEscrowError cobre os que ainda não têm.
      ELIGIBLE_STATUSES = %w[
        ready_to_ship processed retry_ship shipped
        to_confirm_receive completed
      ].freeze

      Result = Struct.new(:outcome, :error_message, :metadata, keyword_init: true) do
        def success? = outcome == :success
        def error? = outcome == :error
        def skipped? = outcome == :skipped
      end

      def self.call(channel_credential, batch_size: DEFAULT_BATCH_SIZE, window_days: DEFAULT_WINDOW_DAYS)
        new(channel_credential, batch_size: batch_size, window_days: window_days).call
      end

      def initialize(channel_credential, batch_size:, window_days:)
        @channel_credential = channel_credential
        @tenant = channel_credential.tenant
        @batch_size = [ batch_size.to_i, 1 ].max
        @window_days = [ window_days.to_i, 1 ].max
        @adapter = Integrations::ShopeeAdapter.new(channel_credential.credentials)
        @lock = EscrowSyncLock.new(channel_credential)
        initialize_counters
      end

      def call
        @channel = tenant.channels.find_by(platform: "shopee")
        return result(:skipped, "canal shopee não encontrado") unless channel
        return result(:skipped, "credencial Shopee não está ativa") unless channel_credential.status == "active"
        return result(:skipped, "escrow sync já em execução") unless lock.acquire

        @lock_acquired = true
        @log = start_log

        pending_orders.each do |order|
          process_order(order)
          lock.renew
          break if @authentication_failed
        end

        finish_log(error_count.positive? ? "error" : "success")
        result(error_count.positive? ? :error : :success, error_samples.first&.fetch(:message, nil))
      rescue Integrations::RateLimitError
        finish_log("pending", "rate limited")
        raise
      ensure
        lock.release if @lock_acquired
      end

      private

      attr_reader :channel_credential, :tenant, :channel, :adapter, :lock,
        :batch_size, :window_days, :log

      def initialize_counters
        @processed_count = 0
        @synced_count = 0
        @pending_count = 0
        @error_count = 0
        @error_samples = []
        @lock_acquired = false
        @authentication_failed = false
      end

      def pending_orders
        channel.orders
          .where(financial_synced_at: nil)
          .where("LOWER(COALESCE(orders.status, '')) IN (?)", ELIGIBLE_STATUSES)
          .where("COALESCE(orders.ordered_at, orders.created_at) >= ?", window_days.days.ago)
          .where("orders.financial_next_attempt_at IS NULL OR orders.financial_next_attempt_at <= ?", Time.current)
          .where("orders.financial_pending_reason IS NULL OR orders.financial_pending_reason != 'authentication_invalid'")
          .order(:id)
          .limit(batch_size)
      end

      def process_order(order)
        mark_attempt(order)

        OrderEscrowSyncService.call(order: order, channel_credential: channel_credential, adapter: adapter)
        @processed_count += 1
        @synced_count += 1
        order.update_columns(financial_pending_reason: nil, financial_next_attempt_at: nil)
      rescue OrderEscrowSyncService::PendingEscrowError
        @processed_count += 1
        @pending_count += 1
        schedule_retry(order, "not_settled")
      rescue Integrations::AuthenticationError => e
        @processed_count += 1
        @error_count += 1
        @authentication_failed = true
        channel_credential.update!(status: "error")
        set_pending_state(order, reason: "authentication_invalid", next_at: nil)
        record_error(order, e.message)
      rescue Integrations::RateLimitError => e
        next_at = Time.current + [ e.retry_after.to_f.to_i, 60 ].max
        set_pending_state(order, reason: "rate_limited", next_at: next_at)
        @pending_count += 1
        raise
      rescue Faraday::Error, Integrations::ApiError => e
        @processed_count += 1
        @error_count += 1
        schedule_retry(order, "temporary_error")
        record_error(order, e.message)
      rescue => e
        @processed_count += 1
        @error_count += 1
        schedule_retry(order, "error")
        record_error(order, e.message)
      end

      def mark_attempt(order)
        order.update_columns(
          financial_sync_attempts: order.financial_sync_attempts.to_i + 1,
          financial_last_attempt_at: Time.current,
          financial_next_attempt_at: nil,
          financial_pending_reason: "in_progress"
        )
      end

      def schedule_retry(order, reason)
        set_pending_state(order, reason: reason, next_at: Time.current + backoff_for(order))
      end

      def set_pending_state(order, reason:, next_at:)
        order.update_columns(financial_pending_reason: reason, financial_next_attempt_at: next_at)
      end

      def backoff_for(order)
        attempts = order.financial_sync_attempts.to_i
        reference = order.ordered_at || order.created_at
        base = reference.present? && reference >= RECENT_DAYS.days.ago ? RECENT_BASE_DELAY : OLD_BASE_DELAY
        [ base * (2**[ attempts - 1, 6 ].min), MAX_DELAY ].min
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

      def finish_log(status, error_message = nil)
        return unless log

        log.update!(
          status: status,
          finished_at: status == "pending" ? nil : Time.current,
          error_message: error_message,
          metadata: (log.metadata || {}).merge(metadata_snapshot)
        )
      end

      def metadata_snapshot
        {
          "channel" => "shopee",
          "channel_credential_id" => channel_credential.id,
          "batch_size" => batch_size,
          "window_days" => window_days,
          "processed_count" => @processed_count,
          "synced_count" => @synced_count,
          "pending_count" => @pending_count,
          "error_count" => @error_count,
          "error_samples" => error_samples
        }
      end

      def record_error(order, message)
        return if error_samples.size >= 20

        error_samples << { order_id: order.id, external_id: order.external_id, message: message }
      end

      def error_count = @error_count
      def error_samples = @error_samples

      def result(outcome, error_message = nil)
        Result.new(outcome: outcome, error_message: error_message, metadata: metadata_snapshot)
      end
    end
  end
end
