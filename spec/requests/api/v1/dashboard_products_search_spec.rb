require "rails_helper"

RSpec.describe "Dashboard products search", type: :request do
  let(:tenant)         { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:operador)       { tenant.users.create!(name: "Operador", email: "op@#{SecureRandom.hex(4)}.com", password: "password123", role: "operador") }
  let(:channel_tiktok) { tenant.channels.create!(name: "TikTok Shop", platform: "tiktok") }
  let(:product)        { tenant.products.create!(sku: "2080", name: "Protetor Solar Clareador") }

  def auth_headers(user)
    { "Authorization" => "Bearer #{JsonWebToken.encode(user_id: user.id)}" }
  end

  describe "GET /api/v1/dashboard/products_search" do
    it "requires authentication" do
      get "/api/v1/dashboard/products_search", params: { q: "2080" }

      expect(response).to have_http_status(:unauthorized)
    end

    it "returns matching products with qty/revenue totals for the current tenant only" do
      order = tenant.orders.create!(
        channel: channel_tiktok, external_id: "order-1", order_number: "N1", order_type: "sale",
        gross_value: 118.90, ordered_at: 1.day.ago
      )
      order.order_items.create!(
        product: product, sku: "2080", name: product.name, quantity: 2,
        unit_price: 35.04, unit_cost: 17.23,
        discount: 48.82, seller_discount: 42.04, platform_discount: 6.78
      )

      get "/api/v1/dashboard/products_search", params: { q: "protetor" }, headers: auth_headers(operador)

      expect(response).to have_http_status(:ok)
      row = JSON.parse(response.body)["results"].first
      expect(row["sku"]).to eq("2080")
      expect(row["total_qty_sold"]).to eq(2.0)
      expect(row["total_revenue"]).to eq(76.86)
      expect(row["by_channel"].first).to include("platform" => "tiktok", "orders_count" => 1, "qty_sold" => 2.0, "revenue" => 76.86)
    end

    it "returns an empty result set for a blank query instead of erroring" do
      get "/api/v1/dashboard/products_search", headers: auth_headers(operador)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["results"]).to eq([])
    end
  end
end
