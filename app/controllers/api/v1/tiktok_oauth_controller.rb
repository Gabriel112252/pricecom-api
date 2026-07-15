module Api
  module V1
    class TiktokOauthController < ApplicationController
      AUTHORIZE_URL = "https://auth.tiktok-shops.com/oauth/authorize".freeze
      MISSING_CREDENTIALS_MESSAGE = "Cadastre App Key e App Secret antes de autorizar".freeze

      skip_before_action :authenticate_request!, only: :callback

      def authorize_url
        credential = current_tenant.channel_credentials.find_by(channel: "tiktok")
        unless tiktok_credentials_configured?(credential)
          return render json: { error: MISSING_CREDENTIALS_MESSAGE }, status: :unprocessable_entity
        end

        render json: { authorize_url: tiktok_authorize_url(credential) }
      end

      def callback
        app_key = params[:app_key].to_s.strip
        auth_code = params[:code].to_s.strip

        return redirect_error("Callback sem código de autorização") if auth_code.blank?

        tenant = resolve_tenant
        return redirect_error("Tenant não identificado no callback do TikTok") unless tenant

        credential = tenant.channel_credentials.find_by(channel: "tiktok")
        return redirect_error(MISSING_CREDENTIALS_MESSAGE) unless tiktok_credentials_configured?(credential)
        return redirect_error("App Key inválida") unless valid_app_key?(app_key, tiktok_app_key(credential))

        token_data = Integrations::TiktokOauthTokenClient
          .new(app_key: tiktok_app_key(credential), app_secret: tiktok_app_secret(credential))
          .exchange(auth_code: auth_code)

        credential = upsert_credential(credential, token_data)
        Channel.ensure_for!(tenant, "tiktok")

        redirect_to frontend_redirect_url("connected", "TikTok Shop conectado", credential_id: credential.id),
          allow_other_host: true
      rescue Integrations::AuthenticationError, Integrations::ApiError, Integrations::RateLimitError => e
        redirect_error(e.message)
      rescue ActiveRecord::RecordInvalid => e
        redirect_error(e.record.errors.full_messages.to_sentence)
      end

      private

      def tiktok_authorize_url(credential)
        uri = URI.parse(AUTHORIZE_URL)
        uri.query = {
          app_key: tiktok_app_key(credential),
          state: oauth_state,
          redirect_uri: tiktok_callback_url
        }.to_query
        uri.to_s
      end

      def oauth_state
        Rails.application.message_verifier(:tiktok_oauth_state)
          .generate({ tenant_id: current_tenant.id }, expires_in: 10.minutes)
      end

      def tiktok_callback_url
        "#{request.base_url.sub(/\Ahttp:/, "https:")}/api/v1/webhooks/tiktok"
      end

      def valid_app_key?(app_key, expected_app_key)
        return false if app_key.blank? || expected_app_key.blank?
        return false unless app_key.bytesize == expected_app_key.bytesize

        ActiveSupport::SecurityUtils.secure_compare(app_key, expected_app_key)
      end

      def tiktok_credentials_configured?(credential)
        tiktok_app_key(credential).present? && tiktok_app_secret(credential).present?
      end

      def tiktok_app_key(credential)
        tiktok_credential_value(credential, "app_key")
      end

      def tiktok_app_secret(credential)
        tiktok_credential_value(credential, "app_secret")
      end

      def tiktok_credential_value(credential, key)
        credentials = (credential&.credentials || {}).to_h
        credentials[key].presence || credentials[key.to_sym].presence
      end

      def resolve_tenant
        state = verified_state
        tenant_id = state[:tenant_id] || state["tenant_id"]
        return Tenant.find_by(id: tenant_id) if tenant_id.present?

        slug = state[:tenant_slug] || state["tenant_slug"] || params[:tenant_slug].presence
        slug.present? ? Tenant.find_by(slug: slug) : nil
      end

      def verified_state
        return {} if params[:state].blank?

        Rails.application.message_verifier(:tiktok_oauth_state).verify(params[:state])
      rescue ActiveSupport::MessageVerifier::InvalidSignature, TypeError
        {}
      end

      def upsert_credential(credential, token_data)
        credential.status = "active"
        credential.credentials = credential.credentials.to_h.merge(
          "access_token" => token_data["access_token"],
          "refresh_token" => token_data["refresh_token"],
          "access_token_expire_in" => token_data["access_token_expire_in"],
          "refresh_token_expire_in" => token_data["refresh_token_expire_in"],
          "open_id" => token_data["open_id"],
          "seller_name" => token_data["seller_name"],
          "seller_base_region" => token_data["seller_base_region"],
          "user_type" => token_data["user_type"],
          "granted_scopes" => token_data["granted_scopes"],
          "shop_region" => params[:shop_region],
          "locale" => params[:locale],
          "oauth_connected_at" => Time.current.iso8601
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
          tiktok: status,
          message: message
        }.merge(extra).to_query
        uri.to_s
      end

      def frontend_base_url
        ENV.fetch("FRONTEND_URL", "http://localhost:5173").delete_suffix("/")
      end
    end
  end
end
