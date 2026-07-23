module Integrations
  module Shopee
    # Renova o access_token (validade ~4h) de uma credential Shopee usando
    # o refresh_token rotativo (30 dias). Com o cron de 3h + a folga de
    # EXPIRY_LEEWAY, um token nunca chega a expirar entre execuções.
    class TokenRefreshJob < ApplicationJob
      queue_as :integrations

      # Só pula o refresh quando o token ainda vive mais que isso — na
      # prática, apenas logo após o OAuth inicial (token de 4h recém-criado).
      EXPIRY_LEEWAY = 3.hours + 30.minutes

      def perform(channel_credential_id)
        channel_credential = ChannelCredential.find_by(id: channel_credential_id)
        return unless channel_credential
        return if channel_credential.credentials.to_h["refresh_token"].blank?
        return unless expiring_soon?(channel_credential)

        Channel.ensure_for!(channel_credential.tenant, "shopee")
        Integrations::ShopeeAuthService.refresh_credential!(channel_credential)
      rescue Integrations::AuthenticationError => e
        # refresh_token rejeitado (expirado/revogado): exige nova autorização
        # manual da loja — marcar "error" tira a credential dos schedulers e
        # acende o estado de erro na tela de integrações.
        channel_credential.update!(status: "error")
        Rails.logger.error("[Integrations::Shopee::TokenRefreshJob] refresh falhou para channel_credential_id=#{channel_credential.id}: #{e.message}")
      rescue Integrations::RateLimitError => e
        self.class.set(wait: (e.retry_after || 60).seconds).perform_later(channel_credential.id)
      end

      private

      def expiring_soon?(channel_credential)
        expires_at = channel_credential.credentials.to_h["token_expires_at"]
        return true if expires_at.blank?

        Time.zone.parse(expires_at.to_s) <= EXPIRY_LEEWAY.from_now
      rescue ArgumentError, TypeError
        true
      end
    end
  end
end
