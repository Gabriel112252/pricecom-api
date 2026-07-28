module Integrations
  module Tiktok
    class ShopAnalyticsSyncJob < ApplicationJob
      queue_as :integrations

      retry_on Integrations::RateLimitError, wait: 1.minute, attempts: 5
      retry_on Faraday::Error, wait: 30.seconds, attempts: 3

      def perform(channel_credential_id, window_days: nil, trigger: "scheduled")
        channel_credential = ChannelCredential.find_by(id: channel_credential_id)
        return unless channel_credential

        Integrations::Tiktok::ShopAnalyticsSyncService.call(
          channel_credential,
          window_days: window_days || Integrations::Tiktok::ShopAnalyticsSyncService::DEFAULT_WINDOW_DAYS,
          trigger:     trigger
        )
      end
    end
  end
end
