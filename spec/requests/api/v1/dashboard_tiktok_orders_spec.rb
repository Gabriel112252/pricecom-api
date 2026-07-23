require "rails_helper"

RSpec.describe "Dashboard TikTok orders", type: :request do
  let(:tenant)         { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:other_tenant)   { Tenant.create!(name: "Outra Loja", slug: "outra-loja-#{SecureRandom.hex(4)}") }
  let(:operador)       { tenant.users.create!(name: "Operador", email: "op@#{SecureRandom.hex(4)}.com", password: "password123", role: "operador") }
  let(:channel_tiktok) { tenant.channels.create!(name: "TikTok Shop", platform: "tiktok") }
  let(:channel_yampi)  { tenant.channels.create!(name: "Yampi", platform: "yampi") }

  def auth_headers(user)
    { "Authorization" => "Bearer #{JsonWebToken.encode(user_id: user.id)}" }
  end

  def make_order(tenant, channel, gross:, ordered_at:, order_type: "sale", **attrs)
    tenant.orders.create!(
      channel: channel, external_id: "order-#{SecureRandom.hex(4)}", order_number: "N#{SecureRandom.hex(3)}",
      order_type: order_type, gross_value: gross, ordered_at: ordered_at, **attrs
    )
  end

  describe "GET /api/v1/dashboard/tiktok_orders" do
    it "returns only TikTok orders for the current tenant, never another tenant's or another channel's" do
      make_order(tenant, channel_tiktok, gross: 50, ordered_at: 1.day.ago, revenue_amount: 45, settlement_amount: 40, financial_synced_at: Time.current)
      make_order(tenant, channel_yampi, gross: 80, ordered_at: 1.day.ago)
      make_order(other_tenant, other_tenant.channels.create!(name: "TikTok", platform: "tiktok"), gross: 99, ordered_at: 1.day.ago)

      get "/api/v1/dashboard/tiktok_orders", headers: auth_headers(operador)

      expect(response).to have_http_status(:ok)
      rows = JSON.parse(response.body)["rows"]
      expect(rows.size).to eq(1)
      expect(rows.first["effective_revenue"]).to eq(45.0)
    end

    it "labels a fully zeroed synced order as refunded and shows margin as nil instead of a misleading zero" do
      make_order(
        tenant, channel_tiktok, gross: 40, ordered_at: 1.day.ago,
        revenue_amount: 0, settlement_amount: 0, fee_and_tax_amount: 0, financial_synced_at: Time.current
      )

      get "/api/v1/dashboard/tiktok_orders", headers: auth_headers(operador)

      row = JSON.parse(response.body)["rows"].first
      expect(row["financial_status"]).to eq("refunded")
      expect(row["margin_pct"]).to be_nil
    end

    it "labels an unsynchronized order as pending" do
      make_order(tenant, channel_tiktok, gross: 40, ordered_at: 1.day.ago)

      get "/api/v1/dashboard/tiktok_orders", headers: auth_headers(operador)

      expect(JSON.parse(response.body)["rows"].first["financial_status"]).to eq("pending")
    end

    it "filters by margin sign" do
      make_order(tenant, channel_tiktok, gross: 40, ordered_at: 1.day.ago, revenue_amount: 40, settlement_amount: 50, cost_price: 10, financial_synced_at: Time.current) # margin +40
      make_order(tenant, channel_tiktok, gross: 40, ordered_at: 1.day.ago, revenue_amount: 40, settlement_amount: 5, cost_price: 30, financial_synced_at: Time.current)  # margin -25

      get "/api/v1/dashboard/tiktok_orders", params: { margin: "negative" }, headers: auth_headers(operador)

      rows = JSON.parse(response.body)["rows"]
      expect(rows.size).to eq(1)
      expect(rows.first["profit"]).to eq(-25.0)
    end

    it "filters by financial status" do
      make_order(tenant, channel_tiktok, gross: 40, ordered_at: 1.day.ago, revenue_amount: 40, settlement_amount: 40, financial_synced_at: Time.current)
      make_order(tenant, channel_tiktok, gross: 40, ordered_at: 1.day.ago)

      get "/api/v1/dashboard/tiktok_orders", params: { financial_status: "pending" }, headers: auth_headers(operador)

      rows = JSON.parse(response.body)["rows"]
      expect(rows.size).to eq(1)
      expect(rows.first["financial_status"]).to eq("pending")
    end

    it "filters by presence of affiliate commission" do
      make_order(tenant, channel_tiktok, gross: 40, ordered_at: 1.day.ago, revenue_amount: 40, settlement_amount: 40, affiliate_commission_amount: 5, financial_synced_at: Time.current)
      make_order(tenant, channel_tiktok, gross: 40, ordered_at: 1.day.ago, revenue_amount: 40, settlement_amount: 40, affiliate_commission_amount: 0, financial_synced_at: Time.current)

      get "/api/v1/dashboard/tiktok_orders", params: { affiliate: "with" }, headers: auth_headers(operador)

      rows = JSON.parse(response.body)["rows"]
      expect(rows.size).to eq(1)
      expect(rows.first["affiliate_commission"]).to eq(5.0)
    end

    it "sorts by profit and paginates" do
      3.times do |i|
        make_order(
          tenant, channel_tiktok, gross: 40, ordered_at: 1.day.ago,
          revenue_amount: 40, settlement_amount: 10 + i, cost_price: 0, financial_synced_at: Time.current
        )
      end

      get "/api/v1/dashboard/tiktok_orders", params: { sort: "profit", direction: "asc", per_page: 2 }, headers: auth_headers(operador)

      body = JSON.parse(response.body)
      expect(body["rows"].size).to eq(2)
      expect(body["rows"].map { |r| r["profit"] }).to eq([ 10.0, 11.0 ])
      expect(body["meta"]).to include("current_page" => 1, "total_pages" => 2, "total_count" => 3)
    end
  end
end
