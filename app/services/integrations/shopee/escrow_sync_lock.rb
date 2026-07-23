module Integrations
  module Shopee
    # Espelho do Integrations::Tiktok::FinancialSyncLock para o escrow da
    # Shopee: garante uma execução de PendingEscrowSyncService por
    # credential (o polling enfileira após cada ingestão — execuções podem
    # se sobrepor sem isso).
    class EscrowSyncLock
      class LockBusyError < StandardError; end

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
        @key = "pricecom:shopee:escrow_sync:#{channel_credential.tenant_id}:#{channel_credential.id}"
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

      def locked?
        redis { |conn| conn.call("EXISTS", key) }.to_i == 1
      end

      private

      attr_reader :channel_credential, :ttl_seconds

      def redis(&block)
        Sidekiq.redis(&block)
      end
    end
  end
end
