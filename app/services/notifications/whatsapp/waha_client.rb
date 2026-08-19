# frozen_string_literal: true

module Notifications
  module Whatsapp
    class WahaClient
      class ConfigurationError < StandardError; end
      class RequestError < StandardError; end

      DEFAULT_SESSION = "default"
      OPEN_TIMEOUT = 3
      READ_TIMEOUT = 10

      def initialize(
        base_url: ENV["WAHA_URL"],
        api_key: ENV["WAHA_API_KEY"],
        session: ENV.fetch("WAHA_SESSION", DEFAULT_SESSION)
      )
        @base_url = base_url.to_s.sub(%r{/+\z}, "")
        @api_key = api_key.to_s
        @session = session.to_s.presence || DEFAULT_SESSION
      end

      def configured?
        base_url.present? && api_key.present?
      end

      def send_text(to:, text:)
        raise ConfigurationError, "WAHA_URL e WAHA_API_KEY precisam estar configurados" unless configured?

        chat_id = normalize_chat_id(to)
        raise ConfigurationError, "Destinatário do WhatsApp inválido" if chat_id.blank?

        response = connection.post("/api/sendText") do |request|
          request.headers["X-Api-Key"] = api_key
          request.headers["Accept"] = "application/json"
          request.headers["Content-Type"] = "application/json"
          request.body = {
            session: session,
            chatId: chat_id,
            text: text.to_s
          }.to_json
        end

        return parse_body(response.body) if response.success?

        raise RequestError, "WAHA respondeu HTTP #{response.status}: #{response.body.to_s.truncate(500)}"
      rescue Faraday::Error => e
        raise RequestError, "Falha ao acessar WAHA: #{e.class}: #{e.message}"
      end

      private

      attr_reader :base_url, :api_key, :session

      def connection
        @connection ||= Faraday.new(url: base_url) do |faraday|
          faraday.options.open_timeout = OPEN_TIMEOUT
          faraday.options.timeout = READ_TIMEOUT
          faraday.adapter Faraday.default_adapter
        end
      end

      def normalize_chat_id(value)
        raw = value.to_s.strip
        return if raw.blank?
        return raw if raw.include?("@")

        digits = raw.gsub(/\D/, "")
        return if digits.blank?

        "#{digits}@c.us"
      end

      def parse_body(body)
        JSON.parse(body)
      rescue JSON::ParserError, TypeError
        body
      end
    end
  end
end
