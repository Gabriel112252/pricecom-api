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

      def initialize(credentials)
        @credentials = credentials.to_h.with_indifferent_access
      end

      # Forces a fresh sign-in — used by IdworksAdapter#authenticate to
      # verify credentials are valid without needing a throwaway data call.
      # Raises AuthenticationError (via AdapterHttp#handle_response) if
      # idworks rejects the email/password.
      def authenticate!
        @token = AuthService.call(credentials)[:token]
        true
      end

      def get(path, params = {})
        response = connection(base_url).get(path, params) { |req| apply_headers(req) }
        handle_response(response)
      end

      private

      attr_reader :credentials

      def token
        @token ||= AuthService.call(credentials)[:token]
      end

      def apply_headers(req)
        req.headers["Authorization"] = "Bearer #{token}"
        req.headers["Origin"]        = AuthService::ORIGIN
        req.headers["FilePath"]      = ""
      end

      def base_url
        "#{credentials[:base_url].to_s.chomp('/')}/"
      end
    end
  end
end
