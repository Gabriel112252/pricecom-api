require "rails_helper"

RSpec.describe Integrations::ProductSyncService do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:base_url) { "https://minha-loja.myshopify.com/admin/api/2024-01" }
  let(:fixture_body) { File.read(Rails.root.join("spec/fixtures/integrations/shopify_products.json")) }

  let(:channel_credential) do
    tenant.channel_credentials.create!(
      channel: "shopify",
      status: "active",
      credentials: { shop_domain: "minha-loja.myshopify.com", access_token: "shpat_abc123", webhook_secret: "wh_secret" }
    )
  end

  def stub_products(status: 200, body: fixture_body, headers: { "Content-Type" => "application/json" })
    # ProductSyncService always calls #authenticate before #fetch_products —
    # stub both so success/error scenarios apply consistently to the whole run.
    stub_request(:get, "#{base_url}/shop.json")
      .to_return(status: status, body: status == 200 ? { shop: { id: 1 } }.to_json : body, headers: headers)
    stub_request(:get, "#{base_url}/products.json")
      .with(query: hash_including("limit" => "250"))
      .to_return(status: status, body: body, headers: headers)
  end

  describe "a successful sync" do
    before { stub_products }

    it "creates a Product per new SKU and a matching ChannelProductListing" do
      result = described_class.call(channel_credential)

      expect(result.outcome).to eq(:success)
      expect(result.synced_count).to eq(3)
      expect(tenant.products.pluck(:sku)).to contain_exactly("IPOD2008PINK", "IPOD2008GREEN", "CASE-SIL-001")

      listing = ChannelProductListing.find_by(tenant: tenant, channel: "shopify", external_id: "808950810")
      expect(listing.external_sku).to eq("IPOD2008PINK")
      expect(listing.price).to eq(BigDecimal("199.00"))
      expect(listing.stock_qty).to eq(BigDecimal("10"))
      expect(listing.product.sku).to eq("IPOD2008PINK")
    end

    it "reuses an existing local Product that already has the same SKU instead of duplicating it" do
      existing = tenant.products.create!(sku: "IPOD2008PINK", name: "Produto já cadastrado manualmente", cost_price: 50)

      described_class.call(channel_credential)

      expect(tenant.products.where(sku: "IPOD2008PINK").count).to eq(1)
      listing = ChannelProductListing.find_by(tenant: tenant, external_id: "808950810")
      expect(listing.product_id).to eq(existing.id)
      expect(existing.reload.name).to eq("Produto já cadastrado manualmente") # not overwritten
    end

    it "updates stock/price on an existing listing on a second sync run rather than creating a duplicate" do
      described_class.call(channel_credential)
      expect(ChannelProductListing.where(tenant: tenant, channel: "shopify").count).to eq(3)

      updated_body = JSON.parse(fixture_body)
      updated_body["products"][0]["variants"][0]["inventory_quantity"] = 2
      stub_products(body: updated_body.to_json)

      described_class.call(channel_credential)

      expect(ChannelProductListing.where(tenant: tenant, channel: "shopify").count).to eq(3) # no duplicates
      listing = ChannelProductListing.find_by(tenant: tenant, external_id: "808950810")
      expect(listing.stock_qty).to eq(BigDecimal("2"))
    end

    it "sets the credential to active and stamps last_synced_at" do
      travel_to(Time.zone.local(2026, 7, 9, 12, 0, 0)) do
        described_class.call(channel_credential)
      end

      expect(channel_credential.reload.status).to eq("active")
      expect(channel_credential.last_synced_at).to eq(Time.zone.local(2026, 7, 9, 12, 0, 0))
    end

    it "logs the attempt in IntegrationSyncLog with the synced count" do
      described_class.call(channel_credential)

      log = IntegrationSyncLog.where(tenant: tenant, action: "product_sync").last
      expect(log.status).to eq("success")
      expect(log.metadata["synced_count"]).to eq(3)
      expect(log.metadata["channel"]).to eq("shopify")
    end
  end

  describe "authentication failure (401/403)" do
    before { stub_products(status: 401, body: { errors: "Invalid access token" }.to_json) }

    it "marks the credential as error and does not create any products" do
      result = described_class.call(channel_credential)

      expect(result.outcome).to eq(:error)
      expect(channel_credential.reload.status).to eq("error")
      expect(tenant.products.count).to eq(0)
    end

    it "logs the failure" do
      described_class.call(channel_credential)

      log = IntegrationSyncLog.where(tenant: tenant, action: "product_sync").last
      expect(log.status).to eq("error")
      expect(log.error_message).to be_present
    end
  end

  describe "rate limiting (429)" do
    before { stub_products(status: 429, body: { errors: "Too Many Requests" }.to_json, headers: { "Retry-After" => "10" }) }

    it "does NOT mark the credential as error (rate limiting isn't a credential problem)" do
      described_class.call(channel_credential)

      expect(channel_credential.reload.status).to eq("active")
    end

    it "logs the rate-limit incident" do
      described_class.call(channel_credential)

      log = IntegrationSyncLog.where(tenant: tenant, action: "product_sync").last
      expect(log.status).to eq("error")
      expect(log.error_message).to include("rate_limited")
    end
  end

  describe "a channel with role=consumidor_pedido" do
    it "is skipped entirely — no HTTP call, no ChannelProductListing created" do
      source = tenant.channel_credentials.create!(channel: "yampi", status: "active", role: "fonte_estoque", credentials: { alias: "a", token: "t", secret_key: "s" })
      channel_credential.update!(role: "consumidor_pedido", stock_source_channel: source)

      # No stub_products call — if the service tried to hit the network,
      # WebMock would raise NetConnectNotAllowedError and fail this spec.
      result = described_class.call(channel_credential)

      expect(result.outcome).to eq(:skipped)
      expect(result.synced_count).to eq(0)
      expect(ChannelProductListing.where(tenant: tenant, channel: "shopify")).to be_empty
    end
  end

  describe "a SKU with no external_sku" do
    before do
      body = JSON.parse(fixture_body)
      body["products"][0]["variants"][0]["sku"] = ""
      stub_products(body: body.to_json)
    end

    it "skips that item but still syncs the others" do
      result = described_class.call(channel_credential)

      expect(result.synced_count).to eq(2)
      expect(result.metadata[:errors]).to include(a_hash_including(message: a_string_matching(/sem SKU/)))
    end
  end
end
