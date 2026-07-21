module Integrations
  module Tiktok
    # Recurring entrypoint for newly completed TikTok orders and orders whose
    # Finance statement was not available during an earlier pass. It shares
    # FinancialBackfillService's credential lock, so it cannot overlap the
    # historical backfill.
    class PendingFinancialSyncJob < ApplicationJob
      queue_as :integrations

      retry_on Integrations::RateLimitError, wait: 1.minute, attempts: 5
      retry_on Faraday::Error, wait: 30.seconds, attempts: 3
      retry_on ActiveRecord::Deadlocked, wait: 5.seconds, attempts: 3

      def perform(channel_credential_id, batch_size: 50, batch_sleep: 0.5)
        channel_credential = ChannelCredential.find_by(id: channel_credential_id)
        return unless channel_credential

        Integrations::Tiktok::FinancialBackfillService.call(
          channel_credential,
          batch_size: batch_size,
          batch_sleep: batch_sleep,
          force: false
        )
      end
    end
  end
end
