require "rails_helper"

RSpec.describe "Stock Overview", type: :request do
  let(:tenant)   { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
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
      expect(shopify["stock_qty"]).to eq("3.0")
      expect(shopify["min_threshold"]).to eq("5.0")

      yampi = row["channels"].find { |c| c["channel"] == "yampi" }
      expect(yampi["stock_qty"]).to eq("8.0")
      expect(yampi["min_threshold"]).to be_nil # no rule for yampi
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
end
