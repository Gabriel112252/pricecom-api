module Integrations
  module Tiktok
    class AffiliateSyncJob < ApplicationJob
      queue_as :integrations

      DEFAULT_RATE_LIMIT_WAIT = 2.minutes
      MIN_RATE_LIMIT_WAIT = 1.minute
      MAX_RATE_LIMIT_WAIT = 30.minutes

      retry_on Integrations::Tiktok::AffiliateSyncLock::LockLostError, wait: 1.minute, attempts: 5
      retry_on Integrations::Tiktok::AffiliateSyncLock::LockBusyError, wait: 2.minutes, attempts: 10
      retry_on Faraday::Error, wait: 30.seconds, attempts: 3
      retry_on ActiveRecord::Deadlocked, wait: 5.seconds, attempts: 3

      def perform(channel_credential_id, run_id: nil)
        channel_credential = ChannelCredential.find_by(id: channel_credential_id)
        return unless channel_credential

        Integrations::Tiktok::AffiliateSyncService.call(channel_credential, run_id: run_id || job_id)
      rescue Integrations::RateLimitError => e
        wait_seconds = rate_limit_wait_seconds(e)
        self.class.set(wait: wait_seconds.seconds).perform_later(channel_credential_id, run_id: run_id || job_id)
      end

      private

      def rate_limit_wait_seconds(error)
        retry_after = error.retry_after.to_f
        retry_after = DEFAULT_RATE_LIMIT_WAIT.to_i unless retry_after.positive?
        retry_after.clamp(MIN_RATE_LIMIT_WAIT.to_i, MAX_RATE_LIMIT_WAIT.to_i)
      end
    end
  end
end
