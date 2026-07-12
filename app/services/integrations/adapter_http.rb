require "faraday"
require "json"

module Integrations
  module AdapterHttp
    MAX_RATE_LIMIT_RETRIES = 3

    private

    def connection(base_url)
      Faraday.new(url: base_url) do |f|
        f.request :json
        f.response :json, content_type: /json/i
        f.adapter Faraday.default_adapter
      end
    end

    def handle_response(response)
      case response.status
      when 200..299
        parse_response_body(response.body)
      when 401, 403
        raise AuthenticationError,
              "#{self.class.name}: credenciais rejeitadas (HTTP #{response.status})"
      when 429
        raise RateLimitError.new(
          "#{self.class.name}: limite de requisições atingido",
          retry_after: response.headers["retry-after"]&.to_i
        )
      else
        raise ApiError,
              "#{self.class.name}: resposta inesperada (HTTP #{response.status}) — #{response.body}"
      end
    end

    def parse_response_body(body)
      return body unless body.is_a?(String)

      JSON.parse(body)
    rescue JSON::ParserError
      body
    end

    def to_decimal(value)
      return nil if value.nil?

      BigDecimal(value.to_s)
    rescue ArgumentError
      nil
    end

    def with_rate_limit_retry
      attempts = 0

      begin
        yield
      rescue RateLimitError => e
        attempts += 1
        raise if attempts > MAX_RATE_LIMIT_RETRIES

        sleep(e.retry_after || (2**attempts))
        retry
      end
    end
  end
end
