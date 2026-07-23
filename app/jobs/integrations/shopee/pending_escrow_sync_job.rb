module Integrations
  module Shopee
    # Enfileirado pelo OrdersPollingService após ingestão com mudanças —
    # sem cron próprio, mesma decisão do PendingFinancialSyncJob do TikTok
    # (o polling de 15min já reagenda o fluxo continuamente).
    class PendingEscrowSyncJob < ApplicationJob
      queue_as :integrations

      def perform(channel_credential_id, batch_size: Integrations::Shopee::PendingEscrowSyncService::DEFAULT_BATCH_SIZE)
        channel_credential = ChannelCredential.find_by(id: channel_credential_id)
        return unless channel_credential

        Integrations::Shopee::PendingEscrowSyncService.call(channel_credential, batch_size: batch_size)
      rescue Integrations::RateLimitError => e
        self.class.set(wait: [ e.retry_after.to_f.to_i, 60 ].max.seconds)
          .perform_later(channel_credential_id, batch_size: batch_size)
      end
    end
  end
end
