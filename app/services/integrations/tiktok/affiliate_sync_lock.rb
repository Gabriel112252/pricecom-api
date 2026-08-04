module Integrations
  module Tiktok
    # Same token-guarded Redis mutex as FinancialSyncLock, own key
    # namespace — kept as a separate small class rather than a shared
    # abstraction, matching how this project already treats
    # FinancialSyncLock as domain-specific rather than generic.
    class AffiliateSyncLock
      class LockBusyError < StandardError; end
      class LockLostError < StandardError; end

      DEFAULT_TTL_SECONDS = 30.minutes.to_i
      RELEASE_SCRIPT = <<~LUA.squish
        if redis.call("GET", KEYS[1]) == ARGV[1] then
          return redis.call("DEL", KEYS[1])
        end
        return 0
      LUA
      RENEW_SCRIPT = <<~LUA.squish
        if redis.call("GET", KEYS[1]) == ARGV[1] then
          return redis.call("EXPIRE", KEYS[1], ARGV[2])
        end
        return 0
      LUA

      attr_reader :key, :token

      def initialize(channel_credential, ttl_seconds: DEFAULT_TTL_SECONDS)
        @channel_credential = channel_credential
        @ttl_seconds = ttl_seconds.to_i.positive? ? ttl_seconds.to_i : DEFAULT_TTL_SECONDS
        @token = SecureRandom.uuid
        @key = "pricecom:tiktok:affiliate_sync:#{channel_credential.tenant_id}:#{channel_credential.id}"
      end

      def acquire
        redis { |conn| conn.call("SET", key, token, "NX", "EX", ttl_seconds) } == "OK"
      end

      def renew
        redis { |conn| conn.call("EVAL", RENEW_SCRIPT, 1, key, token, ttl_seconds) }.to_i == 1
      end

      def release
        redis { |conn| conn.call("EVAL", RELEASE_SCRIPT, 1, key, token) }
      end

      private

      attr_reader :ttl_seconds

      def redis(&block)
        Sidekiq.redis(&block)
      end
    end
  end
end
