require "rails_helper"

RSpec.describe Integrations::WebhookSignatureVerifier do
  let(:secret)   { "shhh-its-a-secret" }
  let(:raw_body) { '{"id":123,"event":"order.created"}' }

  describe ".verifiable?" do
    it "is true for shopify, yampi and tiktok" do
      expect(described_class.verifiable?("shopify")).to eq(true)
      expect(described_class.verifiable?("yampi")).to eq(true)
      expect(described_class.verifiable?("tiktok")).to eq(true)
    end

    it "is false for providers without an implemented scheme" do
      expect(described_class.verifiable?("mercadolivre")).to eq(false)
      expect(described_class.verifiable?("shopee")).to eq(false)
      expect(described_class.verifiable?("unknown")).to eq(false)
    end
  end

  describe ".verify? for shopify/yampi (base64 HMAC-SHA256 over the raw body)" do
    %w[shopify yampi].each do |provider|
      it "accepts a correctly computed #{provider} signature" do
        signature = Base64.strict_encode64(OpenSSL::HMAC.digest("sha256", secret, raw_body))

        expect(described_class.verify?(provider: provider, raw_body: raw_body, header_value: signature, secret: secret)).to eq(true)
      end

      it "rejects a #{provider} signature computed with the wrong secret" do
        signature = Base64.strict_encode64(OpenSSL::HMAC.digest("sha256", "wrong-secret", raw_body))

        expect(described_class.verify?(provider: provider, raw_body: raw_body, header_value: signature, secret: secret)).to eq(false)
      end

      it "rejects when the #{provider} body was tampered with after signing" do
        signature = Base64.strict_encode64(OpenSSL::HMAC.digest("sha256", secret, raw_body))
        tampered_body = raw_body.sub("123", "999")

        expect(described_class.verify?(provider: provider, raw_body: tampered_body, header_value: signature, secret: secret)).to eq(false)
      end
    end
  end

  describe ".verify? for tiktok (hex HMAC-SHA256 over the raw body)" do
    it "accepts a correctly computed signature" do
      signature = OpenSSL::HMAC.hexdigest("sha256", secret, raw_body)

      expect(described_class.verify?(provider: "tiktok", raw_body: raw_body, header_value: signature, secret: secret)).to eq(true)
    end

    it "rejects an incorrect signature" do
      expect(described_class.verify?(provider: "tiktok", raw_body: raw_body, header_value: "deadbeef", secret: secret)).to eq(false)
    end
  end

  describe ".verify? edge cases" do
    it "rejects when secret is blank" do
      signature = Base64.strict_encode64(OpenSSL::HMAC.digest("sha256", secret, raw_body))
      expect(described_class.verify?(provider: "shopify", raw_body: raw_body, header_value: signature, secret: nil)).to eq(false)
    end

    it "rejects when the header value is blank" do
      expect(described_class.verify?(provider: "shopify", raw_body: raw_body, header_value: nil, secret: secret)).to eq(false)
    end

    it "rejects an unrecognized provider even with a matching-looking signature" do
      signature = Base64.strict_encode64(OpenSSL::HMAC.digest("sha256", secret, raw_body))
      expect(described_class.verify?(provider: "unknown", raw_body: raw_body, header_value: signature, secret: secret)).to eq(false)
    end
  end
end
