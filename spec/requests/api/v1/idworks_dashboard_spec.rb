require "rails_helper"

RSpec.describe "Idworks Dashboard", type: :request do
  let(:tenant)   { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:operador) { tenant.users.create!(name: "Operador", email: "op@#{SecureRandom.hex(4)}.com", password: "password123", role: "operador") }
  let(:channel)  { tenant.channels.create!(name: "Yampi", platform: "yampi") }

  def auth_headers(user)
    { "Authorization" => "Bearer #{JsonWebToken.encode(user_id: user.id)}" }
  end

  describe "GET /api/v1/idworks_dashboard" do
    it "returns revenue/orders/top products/channel breakdown for the requested period and loja" do
      integration = tenant.integrations.create!(provider: "idworks", name: "idworks", status: "connected", credentials: {})
      product = tenant.products.create!(sku: "HID-1", name: "Produto Hidrabene", integration: integration)

      order = tenant.orders.create!(
        channel: channel, external_id: "order-1", order_number: "N1", order_type: "sale",
        gross_value: 100, ordered_at: Date.new(2026, 8, 3)
      )
      order.order_items.create!(product: product, sku: product.sku, name: product.name, quantity: 2, unit_price: 50)

      get "/api/v1/idworks_dashboard",
        params: { start_date: "2026-08-01", end_date: "2026-08-07", loja: "hidrabene" },
        headers: auth_headers(operador)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)

      expect(body["period"]).to eq({ "from" => "2026-08-01", "to" => "2026-08-07" })
      expect(body["loja"]).to eq("hidrabene")
      expect(body["orders_count"]).to eq(1)
      expect(body["revenue_total"]).to eq(100.0)
      expect(body["top_products"]).to eq([ { "sku" => "HID-1", "name" => "Produto Hidrabene", "quantity" => 2.0, "revenue" => 100.0 } ])
      expect(body["channel_breakdown"].first["channel"]).to eq("Yampi")
      expect(body["revenue_by_loja"]).to include("hidrabene" => 100.0, "anasol" => 0.0)
    end

    it "defaults the period to the last week when not given" do
      get "/api/v1/idworks_dashboard", headers: auth_headers(operador)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["period"]["from"]).to eq(1.week.ago.to_date.iso8601)
      expect(body["period"]["to"]).to eq(Date.current.iso8601)
    end

    it "rejects invalid dates" do
      get "/api/v1/idworks_dashboard", params: { start_date: "not-a-date" }, headers: auth_headers(operador)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["errors"]).to include("Datas inválidas")
    end
  end
end
