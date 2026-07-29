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

  self.throttled_responder = lambda do |_request|
    [ 429, { "Content-Type" => "application/json" }, [ { error: "Muitas requisições. Tente novamente em instantes." }.to_json ] ]
  end
end
