require "digest"

class Rack::Attack
  # Own store, independent of config.cache_store (which is :null_store in
  # test and configurable per environment) — the throttle counters need a
  # store that actually persists across requests regardless of how the
  # app's business-logic cache is configured.
  Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new

  # Basic per-IP throttle for the public (unauthenticated, cross-origin)
  # storefront-widget API — the only thing under /api/public today (see
  # Api::Public::V1::TestimonialsController). Everything else (the
  # JWT-authenticated admin API) is deliberately left unthrottled here —
  # this is scoped protection for the one route with no auth and no
  # tenant-side control over who calls it, not a global rate limit.
  throttle("public_api/ip", limit: 60, period: 1.minute) do |request|
    request.ip if request.path.start_with?("/api/public/")
  end

  # /mcp é uma superfície nova, externa, com tools de escrita sensíveis
  # (credencial de canal) — diferente do resto da API JWT-autenticada
  # (deixada sem limite acima por design, ver comentário do throttle
  # anterior), aqui vale um teto dedicado por token em vez de herdar
  # "sem limite nenhum". Discrimina pelo próprio mcp_api_key (não pelo IP —
  # um cliente MCP legítimo, tipo Claude Desktop, pode compartilhar IP com
  # outros), lido do mesmo jeito que o monkey-patch de auth do fast-mcp lê
  # (header Authorization ou ?token=) — nunca guardado em claro no cache,
  # só o hash.
  throttle("mcp/token", limit: ENV.fetch("RATE_LIMIT_MCP_PER_MINUTE", 60).to_i, period: 1.minute) do |request|
    next unless request.path.start_with?("/mcp")

    token = request.get_header("HTTP_AUTHORIZATION").to_s.sub(/\ABearer\s+/i, "").strip.presence ||
            request.params["token"].to_s.strip.presence

    Digest::SHA256.hexdigest(token) if token
  end

  self.throttled_responder = lambda do |_request|
    [ 429, { "Content-Type" => "application/json" }, [ { error: "Muitas requisições. Tente novamente em instantes." }.to_json ] ]
  end
end
