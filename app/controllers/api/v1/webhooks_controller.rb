module Api
  module V1
    # Endpoint público — não requer JWT.
    # Tenant identificado via header X-Tenant-Slug ou query param tenant_slug.
    # Assinatura HMAC verificada por provider antes de processar qualquer
    # payload — ver Integrations::WebhookSignatureVerifier.
    class WebhooksController < ApplicationController
      skip_before_action :authenticate_request!
      before_action :set_tenant_from_request!
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
          tenant:        current_tenant,
          integration:   integration,
          provider:      provider,
          event_type:    event_type,
          external_id:   external_id,
          external_type: external_type,
          payload:       payload,
          headers:       safe_headers,
          metadata:      { source: "webhook", ip: request.remote_ip }
        ).call

        if result.success?
          Integrations::ProcessEventJob.perform_later(result.event.id)

          render json: {
            id:           result.event.id,
            status:       result.event.status,
            provider:     result.event.provider,
            event_type:   result.event.event_type,
            external_id:  result.event.external_id
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

      # Reads the signature header straight off the request — NOT off
      # redacted_headers, which deliberately scrubs signature values before
      # they're persisted for logging (see Integrations::HeaderRedactor).
      def verify_signature!
        provider = params[:provider].to_s.downcase
        return unless Integrations::WebhookSignatureVerifier.verifiable?(provider)

        header_name  = Integrations::WebhookSignatureVerifier::SIGNATURE_HEADERS.fetch(provider)
        secret_field = Integrations::WebhookSignatureVerifier::SECRET_FIELDS.fetch(provider)
        credential   = current_tenant.channel_credentials.find_by(channel: provider)

        valid = Integrations::WebhookSignatureVerifier.verify?(
          provider:     provider,
          raw_body:     request.raw_post,
          header_value: request.headers[header_name],
          secret:       credential ? credential.credentials.to_h[secret_field] : nil
        )

        render json: { error: "Assinatura inválida" }, status: :unauthorized unless valid
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
          SecureRandom.uuid
      end

      def extract_external_type(payload, event_type = "")
        payload["resource"] ||
          payload["entity"] ||
          payload["object"] ||
          infer_type_from_event(event_type)
      end

      def infer_type_from_event(event_type)
        et = event_type.to_s.downcase
        return "order"   if et.include?("order")
        return "product" if et.include?("product")
        "unknown"
      end
    end
  end
end
