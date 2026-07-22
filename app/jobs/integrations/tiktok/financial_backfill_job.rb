module Integrations
  module Tiktok
    class FinancialBackfillJob < ApplicationJob
      queue_as :integrations

      retry_on Integrations::Tiktok::FinancialSyncLock::LockLostError, wait: 1.minute, attempts: 5
      retry_on Integrations::Tiktok::FinancialSyncLock::LockBusyError, wait: 2.minutes, attempts: 10
      retry_on Integrations::RateLimitError, wait: 1.minute, attempts: 5
      retry_on Faraday::Error, wait: 30.seconds, attempts: 3
      retry_on ActiveRecord::Deadlocked, wait: 5.seconds, attempts: 3

      def perform(channel_credential_id, batch_size: 50, batch_sleep: 0.5, force: false, max_orders: nil)
        channel_credential = ChannelCredential.find_by(id: channel_credential_id)
        return unless channel_credential

        Integrations::Tiktok::FinancialBackfillService.call(
          channel_credential,
          batch_size: batch_size,
          batch_sleep: batch_sleep,
          force: force,
          max_orders: max_orders,
          run_id: job_id
        )
      end
    end
  end
end
