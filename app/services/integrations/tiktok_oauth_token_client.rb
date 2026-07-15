module Integrations
  class TiktokOauthTokenClient
    include AdapterHttp

    BASE_URL = "https://auth.tiktok-shops.com".freeze
    TOKEN_PATH = "/api/v2/token/get".freeze
    GRANT_TYPE = "authorized_code".freeze

    def initialize(app_key:, app_secret:)
      @app_key = app_key
      @app_secret = app_secret
    end

    def exchange(auth_code:)
      body = get_token(auth_code)
      code = body["code"].to_i
      return body.fetch("data", {}) if code.zero?

      raise ApiError, "TikTok OAuth: #{body['message'].presence || 'falha na troca do código'} (code #{body['code']})"
    end

    private

    attr_reader :app_key, :app_secret

    def get_token(auth_code)
      response = connection(BASE_URL).get(
        TOKEN_PATH,
        app_key: app_key,
        app_secret: app_secret,
        auth_code: auth_code,
        grant_type: GRANT_TYPE
      )

      handle_response(response)
    end
  end
end
