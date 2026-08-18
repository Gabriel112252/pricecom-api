require "rails_helper"

RSpec.describe "Dashboard summary (fast + extended tiers)", type: :request do
  let(:tenant)   { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:operador) { tenant.users.create!(name: "Operador", email: "op@#{SecureRandom.hex(4)}.com", password: "password123", role: "operador") }
  let(:channel)  { tenant.channels.create!(name: "Yampi", platform: "yampi") }

  def auth_headers(user)
    { "Authorization" => "Bearer #{JsonWebToken.encode(user_id: user.id)}" }
  end

  before do
    tenant.orders.create!(
      channel: channel, external_id: "1", order_number: "1", order_type: "sale",
      status: "paid", gross_value: 199.90, ordered_at: 1.day.ago
    )
  end

  describe "GET /api/v1/dashboard/summary" do
    it "requires authentication" do
      get "/api/v1/dashboard/summary"

      expect(response).to have_http_status(:unauthorized)
    end

    it "returns only the fast (Visão Geral) tier — kpis/revenue_breakdown/revenue_timeline/sales_by_channel/regional_sales — without the heavier extended-tier keys" do
      get "/api/v1/dashboard/summary", headers: auth_headers(operador)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)

      expect(body).to include("kpis", "revenue_breakdown", "revenue_timeline", "sales_by_channel", "regional_sales", "coupons", "data_quality")
      expect(body["kpis"]["orders_count"]).to eq(1)
      # Chaves que só existem no tier lento (/summary_extended) — não devem
      # vir na resposta rápida, senão o front não tem como distinguir "ainda
      # não chegou" de "chegou vazio".
      expect(body).not_to include("financial", "margin", "orders", "conflicts", "reconciliation", "cart_abandonment", "freight_margin", "top_products_by_margin")
    end
  end

  describe "GET /api/v1/dashboard/summary_extended" do
    it "requires authentication" do
      get "/api/v1/dashboard/summary_extended"

      expect(response).to have_http_status(:unauthorized)
    end

    it "returns the deferred tier — financial/margin/orders/conflicts/reconciliation/cart_abandonment/freight_margin/top products — without repeating the fast tier's own keys" do
      get "/api/v1/dashboard/summary_extended", headers: auth_headers(operador)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)

      expect(body).to include("financial", "margin", "orders", "conflicts", "reconciliation", "cart_abandonment",
                               "freight_margin", "top_products_by_margin", "top_products_by_revenue", "product_turnover_summary")
      expect(body).not_to include("kpis", "revenue_breakdown", "revenue_timeline", "sales_by_channel", "regional_sales")
    end
  end

  it "the fast tier plus the extended tier together equal the legacy combined payload (Dashboard::BuildSummary.call)" do
    get "/api/v1/dashboard/summary", headers: auth_headers(operador)
    fast = JSON.parse(response.body)

    get "/api/v1/dashboard/summary_extended", headers: auth_headers(operador)
    extended = JSON.parse(response.body)

    expect(fast.keys & extended.keys).to eq([])
    expect((fast.keys + extended.keys).sort).to eq(Dashboard::BuildSummary.call(tenant: tenant, params: {}).deep_stringify_keys.keys.sort)
  end
end
