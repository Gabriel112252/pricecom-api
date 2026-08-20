module Api
  module V1
    class ShopeeOauthController < ApplicationController
      MISSING_CREDENTIALS_MESSAGE = "Cadastre Partner ID e Partner Key antes de autorizar".freeze

      skip_before_action :authenticate_request!, only: :callback

      def authorize_url
        credential = resolve_current_credential
        unless credential
          return render json: { error: credential_resolution_error }, status: :unprocessable_entity
        end

        unless shopee_credentials_configured?(credential)
          return render json: { error: MISSING_CREDENTIALS_MESSAGE }, status: :unprocessable_entity
        end

        authorize_url = auth_service(credential).authorize_url(redirect_url: shopee_callback_url(credential))
        render json: {
          channel_credential_id: credential.id,
          connection_name: credential.display_name,
          authorize_url: authorize_url
        }
      end

      def callback
        code = params[:code].to_s.strip
        shop_id = params[:shop_id].to_s.strip

        return redirect_error("Callback sem código de autorização") if code.blank?
        return redirect_error("Callback sem shop_id (autorização por conta principal não é suportada)") if shop_id.blank?

        state = verified_state
        tenant = resolve_tenant(state)
        return redirect_error("Tenant não identificado no callback da Shopee") unless tenant

        credential = resolve_callback_credential(tenant, state)
        return redirect_error(credential_resolution_error) unless credential
        return redirect_error(MISSING_CREDENTIALS_MESSAGE) unless shopee_credentials_configured?(credential)

        token_data = auth_service(credential).exchange_code(code: code, shop_id: shop_id)

        credential = upsert_credential(credential, token_data, shop_id: shop_id)
        Channel.ensure_for!(tenant, "shopee")

        redirect_to frontend_redirect_url(
          "connected",
          "Shopee conectada",
          credential_id: credential.id,
          connection_name: credential.display_name
        ), allow_other_host: true
      rescue Integrations::AuthenticationError, Integrations::ApiError, Integrations::RateLimitError => e
        redirect_error(e.message)
      rescue ActiveRecord::RecordInvalid => e
        redirect_error(e.record.errors.full_messages.to_sentence)
      end

      private

      def resolve_current_credential
        scope = current_tenant.channel_credentials.where(channel: "shopee")

        if params[:channel_credential_id].present?
          credential = scope.find_by(id: params[:channel_credential_id])
          @credential_resolution_error = "Conexão Shopee não encontrada" unless credential
          return credential
        end

        if params[:name].present?
          credential = scope.find_by(name: params[:name].to_s.strip)
          @credential_resolution_error = "Conexão Shopee '#{params[:name]}' não encontrada" unless credential
          return credential
        end

        records = scope.order(:id).limit(2).to_a
        return records.first if records.one?

        @credential_resolution_error = if records.empty?
          "Shopee ainda não está conectada"
        else
          "Existem várias conexões Shopee; informe channel_credential_id ou name"
        end
        nil
      end

      def resolve_callback_credential(tenant, state)
        credential_id = state[:channel_credential_id] || state["channel_credential_id"]
        if credential_id.present?
          credential = tenant.channel_credentials.find_by(id: credential_id, channel: "shopee")
          @credential_resolution_error = "Conexão Shopee do OAuth não encontrada" unless credential
          return credential
        end

        # Compatibility with authorize URLs created before multi-store.
        records = tenant.channel_credentials.where(channel: "shopee").order(:id).limit(2).to_a
        return records.first if records.one?

        @credential_resolution_error = "Não foi possível identificar qual conexão Shopee deve receber a autorização"
        nil
      end

      def credential_resolution_error
        @credential_resolution_error.presence || "Conexão Shopee não identificada"
      end

      def auth_service(credential)
        Integrations::ShopeeAuthService.new(credential.credentials)
      end

      def shopee_callback_url(credential)
        base = "#{request.base_url.sub(/\Ahttp:/, "https:")}/api/v1/webhooks/shopee"
        "#{base}?#{{ state: oauth_state(credential) }.to_query}"
      end

      def oauth_state(credential)
        Rails.application.message_verifier(:shopee_oauth_state)
          .generate(
            { tenant_id: current_tenant.id, channel_credential_id: credential.id },
            expires_in: 10.minutes
          )
      end

      def shopee_credentials_configured?(credential)
        credential_value(credential, "partner_id").present? &&
          credential_value(credential, "partner_key").present?
      end

      def credential_value(credential, key)
        credentials = (credential&.credentials || {}).to_h
        credentials[key].presence || credentials[key.to_sym].presence
      end

      def resolve_tenant(state)
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
