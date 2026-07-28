module Integrations
  module Tiktok
    class ReturnRefundSyncJob < ApplicationJob
      queue_as :integrations

      retry_on Integrations::RateLimitError, wait: 1.minute, attempts: 5
      retry_on Faraday::Error, wait: 30.seconds, attempts: 3

      def perform(channel_credential_id, order_ids: nil, window_days: nil, trigger: "scheduled")
        channel_credential = ChannelCredential.find_by(id: channel_credential_id)
        return unless channel_credential

        Integrations::Tiktok::ReturnRefundSyncService.call(
          channel_credential,
          order_ids:   order_ids,
          window_days: window_days || Integrations::Tiktok::ReturnRefundSyncService::DEFAULT_WINDOW_DAYS,
          trigger:     trigger
        )
      end
    end
  end
end
