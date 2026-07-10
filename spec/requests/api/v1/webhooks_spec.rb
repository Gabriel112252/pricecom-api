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

    # Regression: Yampi's real webhook envelope wraps the order under a
    # "resource" key ({event, time, merchant, resource: {...}}), which the
    # normalizer and WebhooksController's id/type extraction originally
    # didn't unwrap — see YampiOrderNormalizer's class comment. This drives
    # a real Yampi channel (with a channel per Order#channel) through the
    # full webhook -> IntegrationEvent -> ProcessEventJob -> UpsertOrder
    # pipeline to prove an actual Order gets created with real data instead
    # of a blank/duplicate-colliding one.
    it "creates a correctly-populated Order from a real (resource-enveloped) order.created payload" do
      channel = tenant.channels.create!(name: "Yampi", platform: "yampi")
      real_body = {
        event: "order.created",
        time: "2026-06-15 10:00:00",
        merchant: { id: 123, alias: "loja" },
        resource: {
          id: 1000001,
          number: 555001,
          status: { data: { id: 3, alias: "waiting_payment", name: "Aguardando pagamento" } },
          customer: { data: { id: 987654, name: "Cliente Exemplo" } },
          value_total: 199.90,
          value_shipment: 19.90,
          value_discount: 0.0,
          created_at: "2026-06-15 10:00:00",
          shipping_address: { data: { state: "SP" } },
          items: { data: [
            { id: 111, item_sku: "CAM-001", quantity: 2, price: 90.0, price_cost: 60.0, gift: false, sku: { data: { title: "Camiseta Premium" } } }
          ] }
        }
      }.to_json
      signature = Base64.strict_encode64(OpenSSL::HMAC.digest("sha256", "yampi-webhook-secret", real_body))

      post "/api/v1/webhooks/yampi", params: real_body,
        headers: { "X-Tenant-Slug" => tenant.slug, "Content-Type" => "application/json", "X-Yampi-Hmac-Sha256" => signature }
      expect(response).to have_http_status(:accepted)

      event = IntegrationEvent.last
      expect(event.external_id).to eq("1000001") # not a SecureRandom.uuid fallback
      expect(event.external_type).to eq("order")  # not the resource Hash itself

      Integrations::ProcessEventJob.perform_now(event.id)

      order = tenant.orders.find_by(external_id: "1000001")
      expect(order).to be_present
      expect(order.channel).to eq(channel)
      expect(order.gross_value).to eq(BigDecimal("199.90"))
      expect(order.freight).to eq(BigDecimal("19.90"))
      expect(order.state).to eq("SP")
      expect(order.order_items.sole.sku).to eq("CAM-001")
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
