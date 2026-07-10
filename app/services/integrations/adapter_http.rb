require "faraday"

module Integrations
  # Shared HTTP plumbing for every adapter family (BaseChannelAdapter for
  # sales channels, BaseErpAdapter for ERPs like idworks) — connection
  # setup, response status handling (auth/rate-limit/other errors), decimal
  # parsing, and the rate-limit retry-with-backoff helper are identical
  # across families, so they live here once instead of being copied.
  module AdapterHttp
    MAX_RATE_LIMIT_RETRIES = 3

    private

    def connection(base_url)
      Faraday.new(url: base_url) do |f|
        f.request :json
        f.response :json, content_type: /\bjson$/
        f.adapter Faraday.default_adapter
      end
    end

    # Every adapter funnels its HTTP calls through this so
    # auth/rate-limit/other-error handling is consistent everywhere.
    # Returns the parsed body on 2xx.
    def handle_response(response)
      case response.status
      when 200..299
        response.body
      when 401, 403
        raise AuthenticationError, "#{self.class.name}: credenciais rejeitadas (HTTP #{response.status})"
      when 429
        raise RateLimitError.new(
          "#{self.class.name}: limite de requisições atingido",
          retry_after: response.headers["retry-after"]&.to_i
        )
      else
        raise ApiError, "#{self.class.name}: resposta inesperada (HTTP #{response.status}) — #{response.body}"
      end
    end

    def to_decimal(value)
      return nil if value.nil?

      BigDecimal(value.to_s)
    rescue ArgumentError
      nil
    end

    # Multi-page/multi-item pulls are far more likely to hit a rate limit
    # mid-run than a single-shot call, so this retries transparently —
    # honoring the API's own Retry-After when given (see RateLimitError),
    # falling back to exponential backoff otherwise — instead of letting the
    # caller see the error at all.
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
