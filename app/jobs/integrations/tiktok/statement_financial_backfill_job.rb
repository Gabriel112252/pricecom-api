module Integrations
  module Tiktok
    class StatementFinancialBackfillJob < ApplicationJob
      queue_as :integrations

      DEFAULT_RATE_LIMIT_WAIT = 2.minutes
      MIN_RATE_LIMIT_WAIT = 1.minute
      MAX_RATE_LIMIT_WAIT = 30.minutes

      retry_on Integrations::Tiktok::FinancialSyncLock::LockLostError, wait: 1.minute, attempts: 5
      retry_on Integrations::Tiktok::FinancialSyncLock::LockBusyError, wait: 2.minutes, attempts: 10
      retry_on Faraday::Error, wait: 2.minutes, attempts: 3
      retry_on Integrations::ApiError, wait: 2.minutes, attempts: 3
      retry_on ActiveRecord::Deadlocked, wait: 5.seconds, attempts: 3

      def perform(channel_credential_id, date_from:, date_to:, force: false, run_id: nil, max_statements: nil)
        run_id ||= job_id
        credential = ChannelCredential.find_by(id: channel_credential_id)
        return unless credential

        Integrations::Tiktok::StatementFinancialBackfillService.call(
          credential,
          date_from: date_from,
          date_to: date_to,
          force: force,
          run_id: run_id,
          max_statements: max_statements
        )
      rescue Integrations::RateLimitError => e
        schedule_rate_limit_continuation(
          channel_credential_id: channel_credential_id,
          date_from: date_from,
          date_to: date_to,
          force: force,
          run_id: run_id,
          max_statements: max_statements,
          error: e
        )
      end

      private

      def schedule_rate_limit_continuation(channel_credential_id:, date_from:, date_to:, force:, run_id:, max_statements:, error:)
        credential = ChannelCredential.find_by(id: channel_credential_id)
        return unless credential

        requested_wait = error.retry_after.to_f.to_i
        requested_wait = DEFAULT_RATE_LIMIT_WAIT.to_i unless requested_wait.positive?
        wait_seconds = requested_wait.clamp(MIN_RATE_LIMIT_WAIT.to_i, MAX_RATE_LIMIT_WAIT.to_i)
        continuation_run_at = Time.current + wait_seconds
        scheduled = Integrations::Tiktok::StatementFinancialBackfillService.claim_continuation!(
          channel_credential: credential,
          run_id: run_id,
          continuation_run_at: continuation_run_at
        )
        return unless scheduled

        self.class.set(wait: wait_seconds.seconds).perform_later(
          channel_credential_id,
          date_from: date_from,
          date_to: date_to,
          force: force,
          run_id: run_id,
          max_statements: max_statements
        )
      end
    end
  end
end
