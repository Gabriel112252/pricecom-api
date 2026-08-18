module Integrations
  module Idworks
    # Every authenticated idworks call needs the same three things: a
    # Bearer token (obtained via AuthService), and the Origin/FilePath
    # headers idworks requires on every request (confirmed via
    # swagger.idworks.com.br on 2026-07-10) — centralized here so
    # IdworksAdapter's product/order fetches don't each re-implement the
    # sign-in handshake.
    class BaseClient
      include AdapterHttp

      # Safety margin ahead of the token's real "expiration" (returned by
      # AuthService but, until 2026-08-18, never read) — proactively
      # refreshes slightly before expiry instead of racing a request against
      # the exact cutoff second. Long-running backfills (idworks:backfill_
      # sales_channel over 2 years of history) run well past a single
      # session's lifetime otherwise: the token was signed in once in
      # IdworksAdapter#authenticate and reused forever, so any run longer
      # than the session TTL died mid-run on a 403 from idworks' API
      # Gateway ("no identity-based policy allows the execute-api:Invoke
      # action") with no recovery — see git history for the incident this
      # fixed.
      TOKEN_EXPIRY_SAFETY_MARGIN = 5.minutes

      attr_reader :last_response

      def initialize(credentials)
        @credentials = credentials.to_h.with_indifferent_access
      end

      # Forces a fresh sign-in — used by IdworksAdapter#authenticate to
      # verify credentials are valid without needing a throwaway data call.
      # Raises AuthenticationError (via AdapterHttp#handle_response) if
      # idworks rejects the email/password.
      def authenticate!
        refresh_token!
        true
      end

      # Reactive fallback on top of the proactive #ensure_valid_token check
      # below: if idworks invalidates the session early (clock skew, a
      # shorter real TTL than "expiration" advertised, manual revocation),
      # re-authenticate once and retry the same call instead of letting the
      # whole run die. `retried` guards against looping forever if the
      # credentials are genuinely rejected (wrong email/password) rather
      # than just expired — that still raises, same as before.
      def get(path, params = {}, retried = false)
        ensure_valid_token
        response = connection(base_url).get(path, params) { |req| apply_headers(req) }
        @last_response = response
        handle_response(response)
      rescue AuthenticationError
        raise if retried

        @token = nil
        @token_expiration = nil
        get(path, params, true)
      end

      private

      attr_reader :credentials

      def ensure_valid_token
        refresh_token! if @token.blank? || token_expired?
      end

      def token_expired?
        return false if @token_expiration.blank?

        Time.zone.parse(@token_expiration.to_s) <= Time.current + TOKEN_EXPIRY_SAFETY_MARGIN
      rescue ArgumentError
        false
      end

      def refresh_token!
        result = AuthService.call(credentials)
        @token = result[:token]
        @token_expiration = result[:expiration]
      end

      def apply_headers(req)
        req.headers["Authorization"] = "Bearer #{@token}"
        req.headers["Origin"]        = AuthService::ORIGIN
        req.headers["FilePath"]      = ""
      end

      def base_url
        "#{credentials[:base_url].to_s.chomp('/')}/"
      end
    end
  end
end
