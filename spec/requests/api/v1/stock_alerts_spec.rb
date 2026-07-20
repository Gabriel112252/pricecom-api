require "rails_helper"

RSpec.describe "Stock Alerts", type: :request do
  let(:tenant)   { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:admin)    { tenant.users.create!(name: "Admin", email: "admin@#{SecureRandom.hex(4)}.com", password: "password123", role: "admin") }
  let(:operador) { tenant.users.create!(name: "Operador", email: "op@#{SecureRandom.hex(4)}.com", password: "password123", role: "operador") }
  let(:product)  { tenant.products.create!(sku: "SKU-1", name: "Produto 1", cost_price: 10, qty_available: 100) }

  def auth_headers(user)
    { "Authorization" => "Bearer #{JsonWebToken.encode(user_id: user.id)}" }
  end

  def make_alert(**overrides)
    tenant.stock_alerts.create!(
      {
        product: product, channel: "shopify", qty_at_trigger: 3, target_level: 20,
        suggested_replenishment_qty: 17, automation_level_snapshot: "semi_automatic", status: "awaiting_confirmation"
      }.merge(overrides)
    )
  end

  describe "GET /api/v1/stock_alerts" do
    it "lists the tenant's alerts, paginated" do
      make_alert

      get "/api/v1/stock_alerts", headers: auth_headers(operador)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["stock_alerts"].size).to eq(1)
      expect(body["stock_alerts"].first["product_sku"]).to eq("SKU-1")
      expect(body["meta"]["total_count"]).to eq(1)
    end

    it "filters by status" do
      make_alert(status: "awaiting_confirmation")
      make_alert(status: "executed", executed_at: Time.current)

      get "/api/v1/stock_alerts", params: { status: "executed" }, headers: auth_headers(operador)

      body = JSON.parse(response.body)
      expect(body["stock_alerts"].size).to eq(1)
      expect(body["stock_alerts"].first["status"]).to eq("executed")
    end

    it "filters by channel" do
      make_alert(channel: "shopify")
      make_alert(channel: "yampi")

      get "/api/v1/stock_alerts", params: { channel: "yampi" }, headers: auth_headers(operador)

      body = JSON.parse(response.body)
      expect(body["stock_alerts"].map { |a| a["channel"] }).to eq([ "yampi" ])
    end

    it "does not leak another tenant's alerts" do
      other_tenant = Tenant.create!(name: "Outra Loja", slug: "outra-loja-#{SecureRandom.hex(4)}")
      other_product = other_tenant.products.create!(sku: "SKU-X", name: "Outro", cost_price: 1)
      other_tenant.stock_alerts.create!(
        product: other_product, channel: "shopify", qty_at_trigger: 1, target_level: 5,
        suggested_replenishment_qty: 4, automation_level_snapshot: "manual", status: "pending"
      )

      get "/api/v1/stock_alerts", headers: auth_headers(operador)

      expect(JSON.parse(response.body)["stock_alerts"]).to eq([])
    end
  end

  describe "POST /api/v1/stock_alerts/:id/confirm" do
    it "requires admin" do
      alert = make_alert
      post "/api/v1/stock_alerts/#{alert.id}/confirm", headers: auth_headers(operador)
      expect(response).to have_http_status(:forbidden)
    end

    it "runs the replenishment when the alert is awaiting_confirmation" do
      alert = make_alert(status: "awaiting_confirmation")
      result = StockAlerts::ReplenishmentExecutorService::Result.new(outcome: :success, error_message: nil)
      expect(StockAlerts::ReplenishmentExecutorService).to receive(:call).with(alert).and_return(result)

      post "/api/v1/stock_alerts/#{alert.id}/confirm", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
    end

    it "rejects confirming an alert that isn't awaiting_confirmation" do
      alert = make_alert(status: "executed", executed_at: Time.current)

      post "/api/v1/stock_alerts/#{alert.id}/confirm", headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to match(/executed/)
    end
  end

  describe "POST /api/v1/stock_alerts/:id/dismiss" do
    it "requires admin" do
      alert = make_alert
      post "/api/v1/stock_alerts/#{alert.id}/dismiss", headers: auth_headers(operador)
      expect(response).to have_http_status(:forbidden)
    end

    it "marks an open alert as dismissed without executing anything" do
      alert = make_alert(status: "pending")

      expect(StockAlerts::ReplenishmentExecutorService).not_to receive(:call)
      post "/api/v1/stock_alerts/#{alert.id}/dismiss", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(alert.reload.status).to eq("dismissed")
    end

    it "rejects dismissing an alert that's already resolved" do
      alert = make_alert(status: "failed", error_message: "boom")

      post "/api/v1/stock_alerts/#{alert.id}/dismiss", headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(alert.reload.status).to eq("failed")
    end
  end
end
