module Integrations
  module Yampi
    class RateLimiter
      DEFAULT_REQUESTS_PER_MINUTE = 60
      MAX_REQUESTS_PER_MINUTE = 120
      DEFAULT_RESERVE = 10
      WINDOW_SECONDS = 60

      RESERVE_SCRIPT = <<~LUA.squish
        local current = tonumber(redis.call("GET", KEYS[1]) or "0")
        local limit = tonumber(ARGV[1])
        local window_seconds = tonumber(ARGV[2])
        local ttl = tonumber(redis.call("TTL", KEYS[1]))

        if current >= limit then
          if ttl < 0 then ttl = window_seconds end
          return {0, current, ttl}
        end

        current = current + 1
        if current == 1 then
          redis.call("SET", KEYS[1], current, "EX", window_seconds)
        else
          redis.call("INCR", KEYS[1])
        end

        ttl = tonumber(redis.call("TTL", KEYS[1]))
        if ttl < 0 then ttl = window_seconds end
        return {1, current, ttl}
      LUA

      Reservation = Struct.new(:allowed, :count, :ttl_seconds, keyword_init: true)

      attr_reader :last_limit, :last_remaining

      def initialize(alias_value)
        @alias_value = alias_value.to_s
        @last_limit = nil
        @last_remaining = nil
      end

      def reserve!
        raw = redis do |conn|
          conn.call("EVAL", RESERVE_SCRIPT, 1, key, requests_per_minute, WINDOW_SECONDS)
        end
        allowed, count, ttl = Array(raw)

        Reservation.new(
          allowed: allowed.to_i == 1,
          count: count.to_i,
          ttl_seconds: ttl.to_i
        )
      end

      def retry_after_for(reservation)
        seconds = reservation&.ttl_seconds.to_i
        seconds = WINDOW_SECONDS if seconds <= 0
        seconds + jitter_seconds
      end

      def observe(headers)
        normalized = headers.to_h.transform_keys { |key| key.to_s.downcase }
        @last_limit = normalized["x-ratelimit-limit"]&.to_i
        @last_remaining = normalized["x-ratelimit-remaining"]&.to_i
      end

      def reserve_reached?
        return false if last_remaining.nil?

        last_remaining <= reserve
      end

      def reserve_retry_after
        WINDOW_SECONDS + jitter_seconds
      end

      def requests_per_minute
        configured = ENV.fetch("YAMPI_REQUESTS_PER_MINUTE", DEFAULT_REQUESTS_PER_MINUTE).to_i
        configured = DEFAULT_REQUESTS_PER_MINUTE if configured <= 0
        [ configured, MAX_REQUESTS_PER_MINUTE ].min
      end

      def reserve
        configured = ENV.fetch("YAMPI_RATE_LIMIT_RESERVE", DEFAULT_RESERVE).to_i
        configured.negative? ? DEFAULT_RESERVE : configured
      end

      private

      attr_reader :alias_value

      def key
        "pricecom:yampi:rate_limit:#{alias_value}"
      end

      def jitter_seconds
        SecureRandom.random_number(10)
      end

      def redis(&block)
        Sidekiq.redis(&block)
      end
    end
  end
end
