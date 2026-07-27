require "rails_helper"

RSpec.describe "Reconciliation Overview", type: :request do
  let(:tenant)   { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:operador) { tenant.users.create!(name: "Operador", email: "op@#{SecureRandom.hex(4)}.com", password: "password123", role: "operador") }

  def auth_headers(user)
    { "Authorization" => "Bearer #{JsonWebToken.encode(user_id: user.id)}" }
  end

  describe "GET /api/v1/reconciliation_overview" do
    it "lists ReconciliationItem rows for the requested period, flagging rows past threshold_pct" do
      period_start = Date.new(2026, 7, 20)
      period_end   = Date.new(2026, 7, 27)
      product = tenant.products.create!(sku: "SKU-A", name: "Produto A", cost_price: 5)

      tenant.reconciliation_items.create!(
        sku: "SKU-A", product: product, product_name: product.name,
        period_start: period_start, period_end: period_end,
        idworks_qty: 10, pricecom_qty: 20, diff_qty: 10, diff_pct: 100.0
      )
      tenant.reconciliation_items.create!(
        sku: "SKU-B", product_name: "Sem produto",
        period_start: period_start, period_end: period_end,
        idworks_qty: 10, pricecom_qty: 10, diff_qty: 0, diff_pct: 0.0
      )

      get "/api/v1/reconciliation_overview",
        params: { from: period_start.iso8601, to: period_end.iso8601, threshold_pct: 5 },
        headers: auth_headers(operador)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["items"].size).to eq(2)

      row_a = body["items"].find { |i| i["sku"] == "SKU-A" }
      expect(row_a["divergent"]).to eq(true)
      expect(row_a["diff_pct"]).to eq("100.0")

      row_b = body["items"].find { |i| i["sku"] == "SKU-B" }
      expect(row_b["divergent"]).to eq(false)
    end

    it "does not return items from another period" do
      tenant.reconciliation_items.create!(
        sku: "SKU-A", product_name: "Produto A",
        period_start: Date.new(2026, 1, 1), period_end: Date.new(2026, 1, 7),
        idworks_qty: 10, pricecom_qty: 10, diff_qty: 0
      )

      get "/api/v1/reconciliation_overview",
        params: { from: "2026-07-20", to: "2026-07-27" },
        headers: auth_headers(operador)

      expect(JSON.parse(response.body)["items"]).to be_empty
    end
  end
end
