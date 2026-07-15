module Integrations
  class TiktokAuthorizedShopsClient
    include AdapterHttp
    include TiktokRequestSigning

    BASE_URL = "https://open-api.tiktokglobalshop.com".freeze
    AUTHORIZED_SHOPS_PATH = "/authorization/202309/shops".freeze

    def initialize(app_key:, app_secret:, access_token:)
      @app_key = app_key
      @app_secret = app_secret
      @access_token = access_token
    end

    def fetch
      raise AuthenticationError, "TikTok Authorized Shops: access_token ausente" if access_token.blank?

      body = get_authorized_shops
      code = body["code"].to_i
      return Array(body.dig("data", "shops")) if code.zero?

      raise ApiError,
        "TikTok Authorized Shops: #{body['message'].presence || 'falha ao buscar lojas autorizadas'} (code #{body['code']})"
    end

    private

    attr_reader :app_key, :app_secret, :access_token

    def get_authorized_shops
      params = {
        app_key: app_key,
        timestamp: Time.now.to_i
      }
      params[:sign] = tiktok_sign(AUTHORIZED_SHOPS_PATH, params, app_secret: app_secret)

      response = connection(BASE_URL).get(AUTHORIZED_SHOPS_PATH) do |req|
        req.params = params
        req.headers["x-tts-access-token"] = access_token
        req.headers["Content-Type"] = "application/json"
      end

      handle_response(response)
    end
  end
end
