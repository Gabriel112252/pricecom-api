require "faraday"

module Integrations
  # Common interface every channel adapter implements, so
  # Integrations::ProductSyncService never needs to know which channel
  # it's talking to.
  class BaseChannelAdapter
    # Multi-page pulls (e.g. a 30-day order backfill) are far more likely to
    # hit a rate limit mid-pagination than the single-shot calls the other
    # adapter methods make, so unlike the rest of this class, this one
    # retries transparently — honoring the channel's own Retry-After when
    # given (see RateLimitError), falling back to exponential backoff
    # otherwise — instead of letting the caller see the error at all.
    MAX_RATE_LIMIT_RETRIES = 3

    def initialize(credentials)
      @credentials = credentials.to_h.with_indifferent_access
    end

    # Makes a lightweight authenticated call and raises AuthenticationError
    # if the credentials are rejected. Returns true on success.
    def authenticate
      raise NotImplementedError, "#{self.class} must implement #authenticate"
    end

    # Returns an Array of raw, channel-native hashes — one per purchasable
    # SKU (adapters flatten product/variation nesting internally so every
    # entry here is already 1:1 with #normalize_product).
    def fetch_products
      raise NotImplementedError, "#{self.class} must implement #fetch_products"
    end

    # Looks up current stock for a single external_id. Bulk syncs get stock
    # from #fetch_products already; this exists for a future "refresh one
    # SKU" action and for channels where stock isn't embedded in the
    # product payload.
    def fetch_stock(external_id)
      raise NotImplementedError, "#{self.class} must implement #fetch_stock"
    end

    # Converts one raw hash (as yielded by #fetch_products) into the common
    # shape ProductSyncService upserts from:
    #   { external_id:, external_sku:, name:, price:, stock_qty:, raw: }
    def normalize_product(raw)
      raise NotImplementedError, "#{self.class} must implement #normalize_product"
    end

    private

    attr_reader :credentials

    def connection(base_url)
      Faraday.new(url: base_url) do |f|
        f.request :json
        f.response :json, content_type: /\bjson$/
        f.adapter Faraday.default_adapter
      end
    end

    # Every adapter funnels its HTTP calls through this so
    # auth/rate-limit/other-error handling is consistent across channels.
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
