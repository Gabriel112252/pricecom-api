module Integrations
  module Shopee
    # Disparado pelo sidekiq-cron a cada 3h (ver config/schedule.yml): faz
    # fan-out de um TokenRefreshJob por credential Shopee ativa que já
    # passou pelo OAuth (tem refresh_token). Credentials com status "error"
    # (refresh_token rejeitado) ficam de fora até a loja reautorizar.
    class TokenRefreshSchedulerJob < ApplicationJob
      queue_as :integrations

      def perform
        ChannelCredential
          .active
          .where(channel: "shopee")
          .find_each do |channel_credential|
            next if channel_credential.credentials.to_h["refresh_token"].blank?

            TokenRefreshJob.perform_later(channel_credential.id)
          end
      end
    end
  end
end
