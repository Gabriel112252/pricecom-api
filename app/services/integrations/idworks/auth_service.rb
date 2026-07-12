module Integrations
  module Idworks
    # idworks' only auth mechanism (no OAuth/"app" concept — confirmed via
    # swagger.idworks.com.br on 2026-07-10): POST user/signin/local with
    # email/password, returns a Bearer token + expiration. Used by
    # BaseClient, which signs in lazily and attaches the token (plus the
    # Origin/FilePath headers idworks requires on every subsequent call) to
    # each request — this class only ever performs the sign-in itself.
    class AuthService
      include AdapterHttp

      # idworks requires this exact Origin on every request, including
      # sign-in, or the request is rejected — it's the ERP's own frontend
      # host, not this app's.
      ORIGIN = "https://erp-www.idworks.com.br".freeze

      def self.call(credentials)
        new(credentials).call
      end

      def initialize(credentials)
        @credentials = credentials.to_h.with_indifferent_access
      end

      # → { token:, expiration: }
      def call
        response = connection(base_url).post("user/signin/local") do |req|
          req.headers["Origin"]   = ORIGIN
          req.headers["FilePath"] = ""
          req.body = { email: credentials[:email], password: credentials[:password] }
        end

        body = handle_response(response)
        { token: body["token"], expiration: body["expiration"] }
      end

      private

      attr_reader :credentials

      # Trailing slash matters — Faraday/URI resolves a relative path
      # against the base URL per RFC 3986 "merge" rules (see YampiAdapter's
      # BASE_URL comment for the same gotcha).
      def base_url
        "#{credentials[:base_url].to_s.chomp('/')}/"
      end
    end
  end
end
