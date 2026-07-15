module Integrations
  # Channel-agnostic Redis lock guarding one orders-polling run per
  # ChannelCredential (same semantics as Integrations::Yampi::PollingLock,
  # which predates this class and keeps its own "yampi"-prefixed key for
  # compatibility with in-flight locks). The key embeds the credential's
  # channel, tenant and id, so different channels never contend.
  class OrdersPollingLock
    DEFAULT_TTL_SECONDS = 15.minutes.to_i
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
      @key = "pricecom:#{channel_credential.channel}:orders_polling:#{channel_credential.tenant_id}:#{channel_credential.id}"
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

    def ttl
      redis { |conn| conn.call("TTL", key) }.to_i
    end

    private

    attr_reader :channel_credential, :ttl_seconds

    def redis(&block)
      Sidekiq.redis(&block)
    end
  end
end
