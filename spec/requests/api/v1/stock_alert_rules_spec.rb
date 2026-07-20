require "rails_helper"

RSpec.describe "Stock Alert Rules", type: :request do
  let(:tenant)   { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:admin)    { tenant.users.create!(name: "Admin", email: "admin@#{SecureRandom.hex(4)}.com", password: "password123", role: "admin") }
  let(:operador) { tenant.users.create!(name: "Operador", email: "op@#{SecureRandom.hex(4)}.com", password: "password123", role: "operador") }
  let(:product)  { tenant.products.create!(sku: "SKU-1", name: "Produto 1", cost_price: 10) }

  def auth_headers(user)
    { "Authorization" => "Bearer #{JsonWebToken.encode(user_id: user.id)}" }
  end

  let(:valid_params) { { product_id: product.id, channel: "shopify", min_threshold: 5, target_level: 20, automation_level: "manual" } }

  describe "GET /api/v1/stock_alert_rules" do
    it "lists the tenant's rules" do
      tenant.stock_alert_rules.create!(valid_params)

      get "/api/v1/stock_alert_rules", headers: auth_headers(operador)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body.size).to eq(1)
      expect(body.first["channel"]).to eq("shopify")
      expect(body.first["product_sku"]).to eq("SKU-1")
    end

    it "does not leak another tenant's rules" do
      other_tenant = Tenant.create!(name: "Outra Loja", slug: "outra-loja-#{SecureRandom.hex(4)}")
      other_product = other_tenant.products.create!(sku: "SKU-X", name: "Outro", cost_price: 1)
      other_tenant.stock_alert_rules.create!(valid_params.merge(product_id: other_product.id))

      get "/api/v1/stock_alert_rules", headers: auth_headers(operador)

      expect(JSON.parse(response.body)).to eq([])
    end
  end

  describe "POST /api/v1/stock_alert_rules" do
    it "requires admin" do
      post "/api/v1/stock_alert_rules", params: valid_params, headers: auth_headers(operador)
      expect(response).to have_http_status(:forbidden)
    end

    it "creates a rule for an admin" do
      post "/api/v1/stock_alert_rules", params: valid_params, headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
      expect(tenant.stock_alert_rules.count).to eq(1)
    end

    it "rejects invalid params" do
      post "/api/v1/stock_alert_rules", params: valid_params.merge(target_level: 1), headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["errors"]).to be_present
    end
  end

  describe "PUT /api/v1/stock_alert_rules/:id" do
    it "requires admin" do
      rule = tenant.stock_alert_rules.create!(valid_params)
      put "/api/v1/stock_alert_rules/#{rule.id}", params: { target_level: 30 }, headers: auth_headers(operador)
      expect(response).to have_http_status(:forbidden)
    end

    it "updates the rule" do
      rule = tenant.stock_alert_rules.create!(valid_params)

      put "/api/v1/stock_alert_rules/#{rule.id}", params: { target_level: 30 }, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(rule.reload.target_level).to eq(BigDecimal("30"))
    end
  end

  describe "DELETE /api/v1/stock_alert_rules/:id" do
    it "requires admin" do
      rule = tenant.stock_alert_rules.create!(valid_params)
      delete "/api/v1/stock_alert_rules/#{rule.id}", headers: auth_headers(operador)
      expect(response).to have_http_status(:forbidden)
    end

    it "removes the rule" do
      rule = tenant.stock_alert_rules.create!(valid_params)

      delete "/api/v1/stock_alert_rules/#{rule.id}", headers: auth_headers(admin)

      expect(response).to have_http_status(:no_content)
      expect(StockAlertRule.exists?(rule.id)).to eq(false)
    end
  end
end
