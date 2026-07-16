module Integrations
  # HTTP client for LucroFrete (https://lucrofrete.com.br) — a third-party
  # service that records every freight quote made in the Yampi checkout,
  # including the REAL carrier cost (cost_price) vs the price charged to
  # the customer (price).
  #
  # Auth (confirmed in production, 2026-07-16): POST /api/auth/login with
  # { email, password } returns { "token": "<jwt>", "user": {...} } — the
  # field is literally "token" (not access_token). There is no expires_in;
  # expiry comes from the JWT's own "exp" claim, decoded locally.
  #
  # Session state (access_token + token_expires_at) is cached inside the
  # ChannelCredential's encrypted credentials JSONB, TikTok-style, so a
  # token survives across job runs and is only refreshed when missing or
  # about to expire.
  #
  # NOTE: this environment has no network access to lucrofrete.com.br, so
  # everything below the confirmed facts is written defensively and still
  # needs a production validation pass (see QuotesPollingService).
  class LucrofreteClient
    include AdapterHttp

    # Trailing slash matters — Faraday resolves relative paths against the
    # base URL per RFC 3986 merge rules (see YampiAdapter::BASE_URL).
    BASE_URL = "https://lucrofrete.com.br/api/".freeze
    LOGS_LIMIT = 100 # confirmed max — larger values are truncated server-side
    TOKEN_EXPIRY_MARGIN = 5.minutes
    # Fallback TTL when the JWT can't be decoded — better to reauth too
    # often than to keep using a token we can't reason about.
    FALLBACK_TOKEN_TTL = 1.hour

    def initialize(channel_credential)
      @channel_credential = channel_credential
    end

    # POST /api/auth/login → caches token + expiry on the credential.
    def authenticate!
      body = handle_response(
        connection(BASE_URL).post("auth/login") do |req|
          req.body = { email: credentials["email"], password: credentials["password"] }
        end
      )

      token = body.is_a?(Hash) ? body["token"].to_s : ""
      raise AuthenticationError, "#{self.class.name}: login não retornou 'token' — chaves recebidas: #{body.is_a?(Hash) ? body.keys : body.class}" if token.blank?

      expires_at = decode_jwt_exp(token)
      unless expires_at
        Rails.logger.warn("[Integrations::LucrofreteClient] JWT sem 'exp' decodificável — usando TTL fallback de #{FALLBACK_TOKEN_TTL.inspect}")
        expires_at = FALLBACK_TOKEN_TTL.from_now
      end

      persist_session!(token, expires_at)
      token
    end

    # Reauthenticates when the cached token is missing or within
    # TOKEN_EXPIRY_MARGIN of expiring.
    def ensure_valid_token!
      token      = credentials["access_token"].to_s
      expires_at = parse_time(credentials["token_expires_at"])

      return token if token.present? && expires_at.present? && expires_at > TOKEN_EXPIRY_MARGIN.from_now

      authenticate!
    end

    # GET /api/logs?page=N&limit=100 → { "logs" => [...], "total" =>, "page" =>, "limit" => }.
    # This endpoint does NOT accept date filters (confirmed in production —
    # start_date/end_date are silently ignored here, unlike /api/reports/*).
    # A stale-but-unexpired token revoked server-side comes back as 401 —
    # retried once with a fresh login before giving up.
    def fetch_logs_page(page:, limit: LOGS_LIMIT)
      authorized_get("logs", page: page, limit: limit)
    end

    # GET /api/reports/summary — aggregate of REAL matched orders (not raw
    # quotes; match_rate 99.9% confirmed): total_orders,
    # total_freight_charged, total_freight_cost, total_margin,
    # margin_percent, avg_freight_charged, avg_ticket_order,
    # free_shipping_count, free_shipping_percent, match_rate{}, period{}.
    # Unlike /api/logs, this endpoint DOES honor start_date/end_date
    # (confirmed in production).
    def fetch_summary(start_date:, end_date:)
      authorized_get("reports/summary", start_date: start_date.to_date.iso8601, end_date: end_date.to_date.iso8601)
    end

    # GET /api/reports/timeline — daily array of real matched orders:
    # [{ date ("DD/MM" — no year!), order_count, freight_charged,
    # freight_cost, margin_value, margin_percent }, ...]. Also honors
    # start_date/end_date (confirmed in production).
    def fetch_timeline(start_date:, end_date:)
      authorized_get("reports/timeline", start_date: start_date.to_date.iso8601, end_date: end_date.to_date.iso8601)
    end

    # GET /api/reports/orders — paginated REAL orders already matched by
    # LucroFrete internally. This is now the authoritative source for
    # Order#real_freight_cost (via Lucrofrete::OrdersSyncService), replacing
    # the old best-effort matching against raw /api/logs freight quotes.
    def fetch_orders_report(start_date:, end_date:, page:, per_page: 50)
      page_number = [ page.to_i, 1 ].max
      page_size = per_page.to_i.positive? ? per_page.to_i : 50

      authorized_get(
        "reports/orders",
        start_date: start_date.to_date.iso8601,
        end_date: end_date.to_date.iso8601,
        page: page_number,
        per_page: page_size
      )
    end

    private

    attr_reader :channel_credential

    def credentials
      channel_credential.credentials.to_h.with_indifferent_access
    end

    # Bearer GET with one retry on 401 — a cached, unexpired token can
    # still have been revoked server-side.
    def authorized_get(path, params)
      token = ensure_valid_token!
      get_with_token(path, params, token)
    rescue AuthenticationError
      get_with_token(path, params, authenticate!)
    end

    def get_with_token(path, params, token)
      handle_response(
        connection(BASE_URL).get(path, params) do |req|
          req.headers["Authorization"] = "Bearer #{token}"
        end
      )
    end

    def persist_session!(token, expires_at)
      merged = channel_credential.credentials.to_h.merge(
        "access_token"     => token,
        "token_expires_at" => expires_at.iso8601
      )
      channel_credential.update!(credentials: merged)
    end

    # JWTs are base64url-encoded (RFC 7515) — urlsafe_decode64 with manual
    # padding, NOT plain decode64, which chokes on "-"/"_".
    def decode_jwt_exp(token)
      segment = token.split(".")[1]
      return nil if segment.blank?

      segment += "=" * ((4 - segment.length % 4) % 4)
      payload = JSON.parse(Base64.urlsafe_decode64(segment))
      exp = payload["exp"]
      exp.present? ? Time.zone.at(exp.to_i) : nil
    rescue ArgumentError, JSON::ParserError
      nil
    end

    def parse_time(value)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
