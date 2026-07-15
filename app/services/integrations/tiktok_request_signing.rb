require "json"
require "openssl"

module Integrations
  module TiktokRequestSigning
    private

    def tiktok_sign(path, params, app_secret:, encoded_body: nil)
      base = params
        .except(:sign, "sign", :access_token, "access_token")
        .sort_by { |key, _value| key.to_s }
        .map { |key, value| "#{key}#{value}" }
        .join

      signable = "#{app_secret}#{path}#{base}#{encoded_body}#{app_secret}"
      OpenSSL::HMAC.hexdigest("SHA256", app_secret.to_s, signable)
    end

    def tiktok_json_body(body)
      return nil if body.nil?

      JSON.generate(body)
    end
  end
end
