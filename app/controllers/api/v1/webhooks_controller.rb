module Api
  module V1
    # Endpoint público — não requer JWT.
    # Tenant identificado via header X-Tenant-Slug ou query param tenant_slug.
    # Quando um provider tem várias lojas no mesmo tenant, a URL do webhook
    # precisa carregar channel_credential_id para identificar a conexão exata.
    class WebhooksController < ApplicationController
      skip_before_action :authenticate_request!
      before_action :set_tenant_from_request!
      before_action :set_channel_credential_from_request!
      before_action :verify_signature!

      def receive
        provider     = params[:provider].to_s.downcase
        payload      = parsed_json_payload
        safe_headers = redacted_headers

        event_type    = extract_event_type(payload)
        external_id   = extract_external_id(payload)
        external_type = extract_external_type(payload, event_type)
        integration   = current_tenant.integrations.active.find_by(provider: provider)

        result = Integrations::EventRecorder.new(
          tenant:             current_tenant,
          integration:        integration,
          channel_credential: @webhook_channel_credential,
          provider:           provider,
          event_type:         event_type,
          external_id:        external_id,
          external_type:      external_type,
          payload:            payload,
          headers:            safe_headers,
          metadata:           webhook_metadata
        ).call

        if result.success?
          Integrations::ProcessEventJob.perform_later(result.event.id)

          render json: {
            id:                    result.event.id,
            status:                result.event.status,
            provider:              result.event.provider,
            event_type:            result.event.event_type,
            external_id:           result.event.external_id,
            channel_credential_id: result.event.channel_credential_id
          }, status: :accepted
        else
          render json: { error: result.error_message }, status: :unprocessable_entity
        end
      end

      private

      def set_tenant_from_request!
        slug = request.headers["X-Tenant-Slug"].presence || params[:tenant_slug]
        unless slug
          render json: { error: "X-Tenant-Slug header obrigatório" }, status: :bad_request and return
        end

        @current_tenant = Tenant.find_by(slug: slug)
        unless @current_tenant
          render json: { error: "Tenant não encontrado" }, status: :not_found
        end
      end

      def set_channel_credential_from_request!
        return if performed?

        provider = params[:provider].to_s.downcase
        return unless ChannelCredential::CHANNELS.include?(provider)

        scope = current_tenant.channel_credentials.where(channel: provider)
        requested_id = params[:channel_credential_id].presence || request.headers["X-Channel-Credential-Id"].presence

        if requested_id.present?
          @webhook_channel_credential = scope.find_by(id: requested_id)
          unless @webhook_channel_credential
            render json: { error: "Conexão #{provider} não encontrada para este tenant" }, status: :not_found
          end
          return
        end

        records = scope.order(:id).limit(2).to_a
        @webhook_channel_credential = records.first if records.one?
        return if records.size <= 1

        render json: {
          error: "Existem várias conexões #{provider}; configure este webhook com channel_credential_id na URL"
        }, status: :unprocessable_entity
      end

      # Reads the signature header straight off the request — NOT off
      # redacted_headers, which deliberately scrubs signature values before
      # they're persisted for logging.
      def verify_signature!
        return if performed?

        provider = params[:provider].to_s.downcase
        return unless Integrations::WebhookSignatureVerifier.verifiable?(provider)

        header_name  = Integrations::WebhookSignatureVerifier::SIGNATURE_HEADERS.fetch(provider)
        secret_field = Integrations::WebhookSignatureVerifier::SECRET_FIELDS.fetch(provider)
        credential   = @webhook_channel_credential

        valid = Integrations::WebhookSignatureVerifier.verify?(
          provider:     provider,
          raw_body:     request.raw_post,
          header_value: request.headers[header_name],
          secret:       credential ? credential.credentials.to_h[secret_field] : nil
        )

        render json: { error: "Assinatura inválida" }, status: :unauthorized unless valid
      end

      def webhook_metadata
        metadata = { source: "webhook", ip: request.remote_ip }
        return metadata unless @webhook_channel_credential

        metadata.merge(
          channel_credential_id: @webhook_channel_credential.id,
          connection_name: @webhook_channel_credential.display_name
        )
      end

      def parsed_json_payload
        body = request.raw_post
        return {} if body.blank?
        parsed = JSON.parse(body)
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError
        {}
      end

      def redacted_headers
        raw = request.headers.env
          .select { |k, _| k.start_with?("HTTP_") || k == "CONTENT_TYPE" }
          .transform_keys { |k| k.sub(/^HTTP_/, "").downcase.tr("_", "-") }

        Integrations::HeaderRedactor.call(raw)
      end

      def extract_event_type(payload)
        params[:event_type].presence ||
          payload["event"] ||
          payload["event_type"] ||
          payload["type"] ||
          "unknown"
      end

      def extract_external_id(payload)
        payload["id"]&.to_s ||
          payload["order_id"]&.to_s ||
          payload["resource_id"]&.to_s ||
          payload.dig("order", "id")&.to_s ||
          resource_hash(payload)&.dig("id")&.to_s ||
          SecureRandom.uuid
      end

      def extract_external_type(payload, event_type = "")
        (payload["resource"] if payload["resource"].is_a?(String)) ||
          payload["entity"] ||
          payload["object"] ||
          infer_type_from_event(event_type)
      end

      def resource_hash(payload)
        payload["resource"] if payload["resource"].is_a?(Hash)
      end

      def infer_type_from_event(event_type)
        et = event_type.to_s.downcase
        return "order"   if et.include?("order")
        return "cart"    if et.include?("cart")
        return "product" if et.include?("product")
        "unknown"
      end
    end
  end
end
