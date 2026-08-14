require "rails_helper"

RSpec.describe "Dashboard products timeseries", type: :request do
  let(:tenant)         { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:operador)       { tenant.users.create!(name: "Operador", email: "op@#{SecureRandom.hex(4)}.com", password: "password123", role: "operador") }
  let(:channel_tiktok) { tenant.channels.create!(name: "TikTok Shop", platform: "tiktok") }
  let(:product)        { tenant.products.create!(sku: "2080", name: "Protetor Solar Clareador") }

  def auth_headers(user)
    { "Authorization" => "Bearer #{JsonWebToken.encode(user_id: user.id)}" }
  end

  describe "GET /api/v1/dashboard/products_timeseries" do
    it "requires authentication" do
      get "/api/v1/dashboard/products_timeseries", params: { skus: [ "2080" ] }

      expect(response).to have_http_status(:unauthorized)
    end

    it "returns a zero-filled daily series per SKU for the current tenant only" do
      order = tenant.orders.create!(
        channel: channel_tiktok, external_id: "order-1", order_number: "N1", order_type: "sale",
        gross_value: 118.90, ordered_at: Time.zone.parse("2026-08-10 10:00:00")
      )
      order.order_items.create!(
        product: product, sku: "2080", name: product.name, quantity: 2,
        unit_price: 35.04, unit_cost: 17.23,
        discount: 48.82, seller_discount: 42.04, platform_discount: 6.78
      )

      get "/api/v1/dashboard/products_timeseries",
        params: { skus: [ "2080" ], from: "2026-08-09", to: "2026-08-11" },
        headers: auth_headers(operador)

      expect(response).to have_http_status(:ok)
      series = JSON.parse(response.body)["series"].first
      expect(series["sku"]).to eq("2080")
      expect(series["points"].map { |p| p["date"] }).to eq(%w[2026-08-09 2026-08-10 2026-08-11])
      expect(series["points"][1]).to include("qty_sold" => 2.0, "revenue" => 76.86)
      expect(series["points"][0]).to include("qty_sold" => 0.0, "revenue" => 0.0)
    end

    it "returns an empty series list when skus is blank instead of erroring" do
      get "/api/v1/dashboard/products_timeseries", headers: auth_headers(operador)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["series"]).to eq([])
    end
  end
end
