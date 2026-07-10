require "rails_helper"

RSpec.describe "Webhooks", type: :request do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:body)   { { id: 555, event: "order.created" }.to_json }

  def post_webhook(provider, headers: {})
    post "/api/v1/webhooks/#{provider}", params: body,
      headers: { "X-Tenant-Slug" => tenant.slug, "Content-Type" => "application/json" }.merge(headers)
  end

  describe "providers without a signature scheme (unchanged behavior)" do
    it "still accepts a mercadolivre webhook with no signature at all" do
      post_webhook("mercadolivre")
      expect(response).to have_http_status(:accepted)
    end
  end

  describe "shopify" do
    before do
      tenant.channel_credentials.create!(
        channel: "shopify", status: "active",
        credentials: { shop_domain: "loja.myshopify.com", access_token: "tok", webhook_secret: "shopify-secret" }
      )
    end

    it "accepts a correctly signed payload" do
      signature = Base64.strict_encode64(OpenSSL::HMAC.digest("sha256", "shopify-secret", body))
      post_webhook("shopify", headers: { "X-Shopify-Hmac-Sha256" => signature })
      expect(response).to have_http_status(:accepted)
    end

    it "rejects a missing signature" do
      post_webhook("shopify")
      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects a signature computed with the wrong secret" do
      signature = Base64.strict_encode64(OpenSSL::HMAC.digest("sha256", "not-the-real-secret", body))
      post_webhook("shopify", headers: { "X-Shopify-Hmac-Sha256" => signature })
      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects when no ChannelCredential is connected for this tenant" do
      other_tenant = Tenant.create!(name: "Outra Loja", slug: "outra-loja-#{SecureRandom.hex(4)}")
      signature = Base64.strict_encode64(OpenSSL::HMAC.digest("sha256", "shopify-secret", body))

      post "/api/v1/webhooks/shopify", params: body,
        headers: { "X-Tenant-Slug" => other_tenant.slug, "Content-Type" => "application/json", "X-Shopify-Hmac-Sha256" => signature }

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "yampi" do
    before do
      tenant.channel_credentials.create!(
        channel: "yampi", status: "active",
        credentials: { alias: "loja", token: "tok", secret_key: "yampi-api-secret", webhook_secret: "yampi-webhook-secret" }
      )
    end

    it "accepts a payload signed with the webhook secret (not the API secret_key)" do
      signature = Base64.strict_encode64(OpenSSL::HMAC.digest("sha256", "yampi-webhook-secret", body))
      post_webhook("yampi", headers: { "X-Yampi-Hmac-Sha256" => signature })
      expect(response).to have_http_status(:accepted)
    end

    it "rejects a payload signed with the API secret_key instead of the webhook secret" do
      signature = Base64.strict_encode64(OpenSSL::HMAC.digest("sha256", "yampi-api-secret", body))
      post_webhook("yampi", headers: { "X-Yampi-Hmac-Sha256" => signature })
      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects an invalid signature" do
      post_webhook("yampi", headers: { "X-Yampi-Hmac-Sha256" => "bogus" })
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "tiktok" do
    before do
      tenant.channel_credentials.create!(
        channel: "tiktok", status: "active",
        credentials: { app_key: "key", app_secret: "tiktok-secret", access_token: "tok" }
      )
    end

    it "accepts a correctly signed payload" do
      signature = OpenSSL::HMAC.hexdigest("sha256", "tiktok-secret", body)
      post_webhook("tiktok", headers: { "X-Tts-Signature" => signature })
      expect(response).to have_http_status(:accepted)
    end

    it "rejects an invalid signature" do
      post_webhook("tiktok", headers: { "X-Tts-Signature" => "bogus" })
      expect(response).to have_http_status(:unauthorized)
    end
  end

  it "never leaks the raw signature into stored event headers (redacted before persistence)" do
    tenant.channel_credentials.create!(
      channel: "shopify", status: "active",
      credentials: { shop_domain: "loja.myshopify.com", access_token: "tok", webhook_secret: "shopify-secret" }
    )
    signature = Base64.strict_encode64(OpenSSL::HMAC.digest("sha256", "shopify-secret", body))

    post_webhook("shopify", headers: { "X-Shopify-Hmac-Sha256" => signature })

    event = IntegrationEvent.last
    expect(event.headers["x-shopify-hmac-sha256"]).to eq("[REDACTED]")
  end
end
