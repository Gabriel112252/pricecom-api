module Integrations
  # Verifies an inbound webhook's HMAC signature against the tenant's
  # connected ChannelCredential before WebhooksController does anything
  # with the payload — without this, the webhook receiver would accept any
  # POST that guesses a tenant slug (see WebhooksController's class comment).
  #
  # IMPORTANT: Shopify's scheme (HMAC-SHA256 over the raw body, base64,
  # header X-Shopify-Hmac-Sha256, keyed by the app's Client Secret) is
  # well-documented and this implementation follows Shopify's official
  # webhook docs with confidence. Yampi and TikTok Shop's exact webhook
  # signature schemes could NOT be verified against live docs in this
  # environment (network access to their docs is blocked here — the same
  # limitation already noted for MercadoLivreAdapter/ShopeeAdapter/
  # TiktokAdapter) — they're implemented from general knowledge of each
  # platform's public API conventions (Yampi mirrors Shopify's base64
  # HMAC-SHA256-over-body pattern; TikTok reuses the hex HMAC-SHA256 keyed
  # by app_secret already used for TiktokAdapter's outbound request
  # signing). Confirm both against a real webhook delivery before trusting
  # them to reject traffic in production.
  module WebhookSignatureVerifier
    SIGNATURE_HEADERS = {
      "shopify" => "x-shopify-hmac-sha256",
      "yampi"   => "x-yampi-hmac-sha256",
      "tiktok"  => "x-tts-signature"
    }.freeze

    # Which ChannelCredential#credentials key holds the value each provider
    # signs webhooks with. Shopify's webhook signing secret (the app's
    # Client Secret) is distinct from the access_token used for API calls,
    # so it needs its own credential field — see ChannelCredential::REQUIRED_FIELDS.
    SECRET_FIELDS = {
      "shopify" => "webhook_secret",
      "yampi"   => "secret_key",
      "tiktok"  => "app_secret"
    }.freeze

    def self.verifiable?(provider)
      SIGNATURE_HEADERS.key?(provider)
    end

    def self.verify?(provider:, raw_body:, header_value:, secret:)
      return false if secret.blank? || header_value.blank?

      case provider
      when "shopify", "yampi"
        secure_compare(header_value, base64_hmac(raw_body, secret))
      when "tiktok"
        secure_compare(header_value, hex_hmac(raw_body, secret))
      else
        false
      end
    end

    def self.base64_hmac(raw_body, secret)
      Base64.strict_encode64(OpenSSL::HMAC.digest("sha256", secret, raw_body.to_s))
    end
    private_class_method :base64_hmac

    def self.hex_hmac(raw_body, secret)
      OpenSSL::HMAC.hexdigest("sha256", secret, raw_body.to_s)
    end
    private_class_method :hex_hmac

    def self.secure_compare(a, b)
      ActiveSupport::SecurityUtils.secure_compare(a, b)
    rescue ArgumentError
      # secure_compare raises if the strings differ in bytesize instead of
      # returning false — a mismatched signature is exactly that case.
      false
    end
    private_class_method :secure_compare
  end
end
