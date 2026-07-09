module Integrations
  module HeaderRedactor
    SENSITIVE_KEYS = %w[
      authorization
      x-api-key
      api-key
      token
      secret
      signature
      x-yampi-token
      x-shopify-hmac-sha256
    ].freeze

    def self.call(headers)
      headers.transform_values.with_index do |value, i|
        key = headers.keys[i].to_s.downcase
        SENSITIVE_KEYS.any? { |s| key.include?(s) } ? "[REDACTED]" : value
      end
    end
  end
end
