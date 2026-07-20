require "rails_helper"

RSpec.describe "Stock Overview", type: :request do
  let(:tenant)   { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:admin)    { tenant.users.create!(name: "Admin", email: "admin@#{SecureRandom.hex(4)}.com", password: "password123", role: "admin") }
  let(:operador) { tenant.users.create!(name: "Operador", email: "op@#{SecureRandom.hex(4)}.com", password: "password123", role: "operador") }

  def auth_headers(user)
    { "Authorization" => "Bearer #{JsonWebToken.encode(user_id: user.id)}" }
  end

  describe "GET /api/v1/stock_overview" do
    it "returns each product with idworks qty_available and every channel's stock_qty + rule threshold" do
      product = tenant.products.create!(sku: "SKU-1", name: "Produto 1", cost_price: 10, qty_available: 42)
      tenant.channel_product_listings.create!(product: product, channel: "shopify", external_id: "1", stock_qty: 3)
      tenant.channel_product_listings.create!(product: product, channel: "yampi", external_id: "2", stock_qty: 8)
      tenant.stock_alert_rules.create!(product: product, channel: "shopify", min_threshold: 5, target_level: 20)

      get "/api/v1/stock_overview", headers: auth_headers(operador)

      expect(response).to have_http_status(:ok)
      row = JSON.parse(response.body)["products"].first
      expect(row["sku"]).to eq("SKU-1")
      expect(row["qty_available"]).to eq("42.0")

      shopify = row["channels"].find { |c| c["channel"] == "shopify" }
      expect(shopify["listing_id"]).to eq(tenant.channel_product_listings.find_by!(channel: "shopify").id)
      expect(shopify["stock_qty"]).to eq("3.0")
      expect(shopify["min_threshold"]).to eq("5.0")

      yampi = row["channels"].find { |c| c["channel"] == "yampi" }
      expect(yampi["stock_qty"]).to eq("8.0")
      expect(yampi["min_threshold"]).to be_nil # no rule for yampi
      expect(JSON.parse(response.body)["active_channels"]).to eq([])
    end

    it "filters by SKU/name" do
      tenant.products.create!(sku: "CAM-001", name: "Camiseta", cost_price: 10)
      tenant.products.create!(sku: "CAN-001", name: "Caneca", cost_price: 5)

      get "/api/v1/stock_overview", params: { q: "camiseta" }, headers: auth_headers(operador)

      skus = JSON.parse(response.body)["products"].map { |p| p["sku"] }
      expect(skus).to eq([ "CAM-001" ])
    end

    it "filters by channel" do
      with_listing = tenant.products.create!(sku: "SKU-1", name: "Produto 1", cost_price: 10)
      without_listing = tenant.products.create!(sku: "SKU-2", name: "Produto 2", cost_price: 10)
      tenant.channel_product_listings.create!(product: with_listing, channel: "yampi", external_id: "1", stock_qty: 3)

      get "/api/v1/stock_overview", params: { channel: "yampi" }, headers: auth_headers(operador)

      skus = JSON.parse(response.body)["products"].map { |p| p["sku"] }
      expect(skus).to eq([ "SKU-1" ])
      expect(without_listing).to be_present # not referenced further, just proving it exists and was excluded
    end

    it "does not leak another tenant's products" do
      other_tenant = Tenant.create!(name: "Outra Loja", slug: "outra-loja-#{SecureRandom.hex(4)}")
      other_tenant.products.create!(sku: "SKU-X", name: "Outro", cost_price: 1)

      get "/api/v1/stock_overview", headers: auth_headers(operador)

      expect(JSON.parse(response.body)["products"]).to eq([])
    end
  end

  describe "PATCH /api/v1/channel_product_listings/:id" do
    let(:product) do
      tenant.products.create!(sku: "SKU-EDIT", name: "Produto editável", cost_price: 10, qty_available: 100)
    end

    def make_credential(channel, credentials)
      tenant.channel_credentials.create!(channel: channel, status: "active", credentials: credentials)
    end

    it "requires admin and does not invoke the adapter for an operator" do
      listing = tenant.channel_product_listings.create!(product: product, channel: "yampi", external_id: "y-1", stock_qty: 3)

      patch "/api/v1/channel_product_listings/#{listing.id}",
        params: { quantity: 10 }, headers: auth_headers(operador)

      expect(response).to have_http_status(:forbidden)
      expect(listing.reload.stock_qty).to eq(3)
    end

    it "writes Yampi first, then updates the local listing and audit log" do
      credential = make_credential("yampi", { alias: "loja", token: "token", secret_key: "secret", webhook_secret: "webhook" })
      listing = tenant.channel_product_listings.create!(product: product, channel: "yampi", external_id: "y-1", stock_qty: 3)
      adapter = instance_double(Integrations::YampiAdapter)

      allow(Integrations::ProductSyncService).to receive(:adapter_for).with(credential).and_return(adapter)
      expect(adapter).to receive(:update_stock).with(external_id: "y-1", quantity: BigDecimal("10"))

      patch "/api/v1/channel_product_listings/#{listing.id}",
        params: { quantity: 10 }, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to include("id" => listing.id, "stock_qty" => "10.0")
      expect(listing.reload.stock_qty).to eq(BigDecimal("10"))

      log = tenant.integration_sync_logs.find_by!(action: "manual_stock_update")
      expect(log.status).to eq("success")
      expect(log.direction).to eq("outbound")
      expect(log.metadata).to include("user_id" => admin.id, "channel" => "yampi")
    end

    it "passes Shopify's inventory_item_id as the channel-specific kwarg" do
      credential = make_credential("shopify", { shop_domain: "store.myshopify.com", access_token: "token", webhook_secret: "webhook" })
      listing = tenant.channel_product_listings.create!(
        product: product, channel: "shopify", external_id: "variant-1", external_inventory_item_id: "inventory-1", stock_qty: 3
      )
      adapter = instance_double(Integrations::ShopifyAdapter)

      allow(Integrations::ProductSyncService).to receive(:adapter_for).with(credential).and_return(adapter)
      expect(adapter).to receive(:update_stock).with(
        external_id: "variant-1", quantity: BigDecimal("12"), inventory_item_id: "inventory-1"
      )

      patch "/api/v1/channel_product_listings/#{listing.id}",
        params: { quantity: 12 }, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(listing.reload.stock_qty).to eq(BigDecimal("12"))
    end

    it "passes TikTok's external product id as product_id" do
      credential = make_credential("tiktok", { app_key: "app", app_secret: "secret" })
      listing = tenant.channel_product_listings.create!(
        product: product, channel: "tiktok", external_id: "sku-1", external_product_id: "product-1", stock_qty: 3
      )
      adapter = instance_double(Integrations::TiktokAdapter)

      allow(Integrations::ProductSyncService).to receive(:adapter_for).with(credential).and_return(adapter)
      expect(adapter).to receive(:update_stock).with(
        external_id: "sku-1", quantity: BigDecimal("14"), product_id: "product-1"
      )

      patch "/api/v1/channel_product_listings/#{listing.id}",
        params: { quantity: 14 }, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(listing.reload.stock_qty).to eq(BigDecimal("14"))
    end

    it "returns the adapter error and leaves the local quantity unchanged" do
      credential = make_credential("yampi", { alias: "loja", token: "token", secret_key: "secret", webhook_secret: "webhook" })
      listing = tenant.channel_product_listings.create!(product: product, channel: "yampi", external_id: "y-1", stock_qty: 3)
      adapter = instance_double(Integrations::YampiAdapter)

      allow(Integrations::ProductSyncService).to receive(:adapter_for).with(credential).and_return(adapter)
      allow(adapter).to receive(:update_stock).and_raise(Integrations::ApiError, "Yampi recusou a quantidade")

      patch "/api/v1/channel_product_listings/#{listing.id}",
        params: { quantity: 10 }, headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to eq("Yampi recusou a quantidade")
      expect(listing.reload.stock_qty).to eq(BigDecimal("3"))
      expect(tenant.integration_sync_logs.find_by!(action: "manual_stock_update").status).to eq("error")
    end
  end
end
