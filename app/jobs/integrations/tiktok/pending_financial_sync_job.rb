module Integrations
  module Tiktok
    # Asynchronous, bounded retry queue for orders whose statement is not yet
    # available. It shares the credential lock with both backfill strategies.
    class PendingFinancialSyncJob < ApplicationJob
      queue_as :integrations

      retry_on Integrations::Tiktok::FinancialSyncLock::LockLostError, wait: 1.minute, attempts: 5
      retry_on Integrations::Tiktok::FinancialSyncLock::LockBusyError, wait: 2.minutes, attempts: 10
      retry_on Integrations::RateLimitError, wait: 1.minute, attempts: 5
      retry_on Faraday::Error, wait: 30.seconds, attempts: 3
      retry_on ActiveRecord::Deadlocked, wait: 5.seconds, attempts: 3

      def perform(channel_credential_id, order_ids: nil, batch_size: 100, window_days: nil, run_id: nil, batch_sleep: nil)
        channel_credential = ChannelCredential.find_by(id: channel_credential_id)
        return unless channel_credential

        # Keep already-enqueued callers from the previous release resumable;
        # the new scheduler does not pass batch_sleep and uses the bounded
        # pending queue below.
        if batch_sleep.present? && order_ids.blank? && window_days.nil? && run_id.nil?
          return Integrations::Tiktok::FinancialBackfillService.call(
            channel_credential,
            batch_size: batch_size,
            batch_sleep: batch_sleep,
            force: false
          )
        end

        result = Integrations::Tiktok::PendingFinancialSyncService.call(
          channel_credential,
          order_ids: order_ids,
          batch_size: batch_size,
          window_days: window_days || Integrations::Tiktok::PendingFinancialSyncService::DEFAULT_WINDOW_DAYS,
          run_id: run_id || job_id
        )
        schedule_pending_continuation(
          channel_credential_id: channel_credential_id,
          order_ids: order_ids,
          batch_size: batch_size,
          window_days: window_days,
          run_id: run_id || job_id,
          wait_seconds: pending_wait_seconds(result.metadata)
        ) if result.metadata.to_h["pending_count"].to_i.positive?
      end

      private

      def pending_wait_seconds(metadata)
        value = metadata.to_h["next_retry_at"]
        return Integrations::Tiktok::PendingFinancialSyncService::RECENT_BASE_DELAY.to_i if value.blank?

        value.to_time.to_i - Time.current.to_i
      end

      def schedule_pending_continuation(channel_credential_id:, order_ids:, batch_size:, window_days:, run_id:, wait_seconds:)
        wait_seconds = wait_seconds.to_i
        wait_seconds = Integrations::Tiktok::PendingFinancialSyncService::RECENT_BASE_DELAY.to_i if wait_seconds <= 0
        self.class.set(wait: wait_seconds.seconds).perform_later(
          channel_credential_id,
          order_ids: order_ids,
          batch_size: batch_size,
          window_days: window_days,
          run_id: run_id
        )
      end
    end
  end
end
