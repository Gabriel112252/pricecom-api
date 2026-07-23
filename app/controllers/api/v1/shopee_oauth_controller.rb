module Api
  module V1
    # OAuth de loja da Shopee, nos moldes do TiktokOauthController: o admin
    # pede a authorize_url (autenticado), autoriza a loja no site da Shopee
    # e ela redireciona o navegador de volta com GET para
    # /api/v1/webhooks/shopee levando code + shop_id.
    #
    # A Shopee não tem um parâmetro `state` próprio: o tenant vai embutido
    # como query param dentro da própria URL de redirect (a Shopee preserva
    # os params existentes ao anexar code/shop_id), assinado com
    # message_verifier igual ao fluxo do TikTok.
    class ShopeeOauthController < ApplicationController
      MISSING_CREDENTIALS_MESSAGE = "Cadastre Partner ID e Partner Key antes de autorizar".freeze

      skip_before_action :authenticate_request!, only: :callback

      def authorize_url
        credential = current_tenant.channel_credentials.find_by(channel: "shopee")
        unless shopee_credentials_configured?(credential)
          return render json: { error: MISSING_CREDENTIALS_MESSAGE }, status: :unprocessable_entity
        end

        authorize_url = auth_service(credential).authorize_url(redirect_url: shopee_callback_url)
        render json: { authorize_url: authorize_url }
      end

      def callback
        code = params[:code].to_s.strip
        shop_id = params[:shop_id].to_s.strip

        return redirect_error("Callback sem código de autorização") if code.blank?
        # main_account_id no lugar de shop_id = autorização por conta
        # principal (multi-loja), fluxo que o modelo atual não suporta —
        # mesma restrição de uma-loja-por-credencial do TikTok.
        return redirect_error("Callback sem shop_id (autorização por conta principal não é suportada)") if shop_id.blank?

        tenant = resolve_tenant
        return redirect_error("Tenant não identificado no callback da Shopee") unless tenant

        credential = tenant.channel_credentials.find_by(channel: "shopee")
        return redirect_error(MISSING_CREDENTIALS_MESSAGE) unless shopee_credentials_configured?(credential)

        token_data = auth_service(credential).exchange_code(code: code, shop_id: shop_id)

        credential = upsert_credential(credential, token_data, shop_id: shop_id)
        Channel.ensure_for!(tenant, "shopee")

        redirect_to frontend_redirect_url("connected", "Shopee conectada", credential_id: credential.id),
          allow_other_host: true
      rescue Integrations::AuthenticationError, Integrations::ApiError, Integrations::RateLimitError => e
        redirect_error(e.message)
      rescue ActiveRecord::RecordInvalid => e
        redirect_error(e.record.errors.full_messages.to_sentence)
      end

      private

      def auth_service(credential)
        Integrations::ShopeeAuthService.new(credential.credentials)
      end

      def shopee_callback_url
        base = "#{request.base_url.sub(/\Ahttp:/, "https:")}/api/v1/webhooks/shopee"
        "#{base}?#{{ state: oauth_state }.to_query}"
      end

      def oauth_state
        Rails.application.message_verifier(:shopee_oauth_state)
          .generate({ tenant_id: current_tenant.id }, expires_in: 10.minutes)
      end

      def shopee_credentials_configured?(credential)
        credential_value(credential, "partner_id").present? &&
          credential_value(credential, "partner_key").present?
      end

      def credential_value(credential, key)
        credentials = (credential&.credentials || {}).to_h
        credentials[key].presence || credentials[key.to_sym].presence
      end

      def resolve_tenant
        state = verified_state
        tenant_id = state[:tenant_id] || state["tenant_id"]
        tenant_id.present? ? Tenant.find_by(id: tenant_id) : nil
      end

      def verified_state
        return {} if params[:state].blank?

        Rails.application.message_verifier(:shopee_oauth_state).verify(params[:state])
      rescue ActiveSupport::MessageVerifier::InvalidSignature, TypeError
        {}
      end

      def upsert_credential(credential, token_data, shop_id:)
        now = Time.current
        credential.status = "active"
        credential.credentials = credential.credentials.to_h.merge(
          "shop_id"                  => shop_id,
          "access_token"             => token_data["access_token"],
          "refresh_token"            => token_data["refresh_token"],
          "token_expires_at"         => (now + token_data["expire_in"].to_i.seconds).iso8601,
          "refresh_token_expires_at" => (now + Integrations::ShopeeAuthService::REFRESH_TOKEN_TTL).iso8601,
          "oauth_connected_at"       => now.iso8601
        ).compact
        credential.save!
        credential
      end

      def redirect_error(message)
        redirect_to frontend_redirect_url("error", message), allow_other_host: true
      end

      def frontend_redirect_url(status, message, extra = {})
        uri = URI.parse("#{frontend_base_url}/integracoes")
        uri.query = {
          shopee: status,
          message: message
        }.merge(extra).to_query
        uri.to_s
      end

      def frontend_base_url
        ENV.fetch("FRONTEND_URL", "https://pricecom-pricecom-web.dzxtro.easypanel.host").delete_suffix("/")
      end
    end
  end
end
