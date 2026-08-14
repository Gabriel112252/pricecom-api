require "rails_helper"

RSpec.describe "Products turnover", type: :request do
  let(:tenant)   { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:operador) { tenant.users.create!(name: "Operador", email: "op@#{SecureRandom.hex(4)}.com", password: "password123", role: "operador") }
  let(:channel)  { tenant.channels.create!(name: "Yampi", platform: "yampi") }
  let(:product)  { tenant.products.create!(sku: "2080", name: "Protetor Solar Clareador") }

  def auth_headers(user)
    { "Authorization" => "Bearer #{JsonWebToken.encode(user_id: user.id)}" }
  end

  def make_item_order(order_type: "sale", status: "COMPLETED", quantity:, unit_price:)
    order = tenant.orders.create!(
      channel: channel, external_id: "order-#{SecureRandom.hex(4)}", order_number: "N#{SecureRandom.hex(3)}",
      order_type: order_type, status: status, gross_value: unit_price * quantity, ordered_at: 1.day.ago
    )
    order.order_items.create!(product: product, sku: "2080", name: product.name, quantity: quantity, unit_price: unit_price, unit_cost: 10)
  end

  describe "GET /api/v1/products/:id/turnover" do
    it "excludes sample and cancelled orders from direct_sales_qty" do
      make_item_order(quantity: 3, unit_price: 50)
      make_item_order(order_type: "sample", quantity: 10, unit_price: 0)
      make_item_order(status: "cancelled", quantity: 20, unit_price: 999)

      get "/api/v1/products/#{product.id}/turnover", headers: auth_headers(operador)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["direct_sales_qty"]).to eq(3)
    end
  end
end
