module Integrations
  module Tiktok
    class FinancialBackfillJob < ApplicationJob
      queue_as :integrations

      DEFAULT_RATE_LIMIT_WAIT = 2.minutes
      MIN_RATE_LIMIT_WAIT = 1.minute
      MAX_RATE_LIMIT_WAIT = 30.minutes

      retry_on Integrations::Tiktok::FinancialSyncLock::LockLostError, wait: 1.minute, attempts: 5
      retry_on Integrations::Tiktok::FinancialSyncLock::LockBusyError, wait: 2.minutes, attempts: 10
      retry_on Faraday::Error, wait: 30.seconds, attempts: 3
      retry_on ActiveRecord::Deadlocked, wait: 5.seconds, attempts: 3

      def perform(
        channel_credential_id,
        batch_size: 50,
        batch_sleep: 0.5,
        force: false,
        max_orders: nil,
        run_id: nil
      )
        run_id ||= job_id
        channel_credential = ChannelCredential.find_by(id: channel_credential_id)
        return unless channel_credential

        Integrations::Tiktok::FinancialBackfillService.clear_due_continuation!(
          channel_credential: channel_credential,
          force: force,
          run_id: run_id
        )

        Integrations::Tiktok::FinancialBackfillService.call(
          channel_credential,
          batch_size: batch_size,
          batch_sleep: batch_sleep,
          force: force,
          max_orders: max_orders,
          run_id: run_id
        )
      rescue Integrations::RateLimitError => e
        schedule_rate_limit_continuation(
          channel_credential: channel_credential,
          channel_credential_id: channel_credential_id,
          batch_size: batch_size,
          batch_sleep: batch_sleep,
          force: force,
          max_orders: max_orders,
          run_id: run_id,
          error: e
        )
      end

      private

      def schedule_rate_limit_continuation(
        channel_credential:,
        channel_credential_id:,
        batch_size:,
        batch_sleep:,
        force:,
        max_orders:,
        run_id:,
        error:
      )
        return unless channel_credential

        wait_seconds = rate_limit_wait_seconds(error)
        continuation_run_at = Time.current + wait_seconds
        scheduled = Integrations::Tiktok::FinancialBackfillService.claim_continuation!(
          channel_credential: channel_credential,
          force: force,
          run_id: run_id,
          continuation_run_at: continuation_run_at
        )
        return unless scheduled

        self.class.set(wait: wait_seconds.seconds).perform_later(
          channel_credential_id,
          batch_size: batch_size,
          batch_sleep: batch_sleep,
          force: force,
          max_orders: max_orders,
          run_id: run_id
        )
      end

      def rate_limit_wait_seconds(error)
        retry_after = error.retry_after.to_f
        retry_after = DEFAULT_RATE_LIMIT_WAIT.to_i unless retry_after.positive?
        retry_after.clamp(MIN_RATE_LIMIT_WAIT.to_i, MAX_RATE_LIMIT_WAIT.to_i)
      end
    end
  end
end
