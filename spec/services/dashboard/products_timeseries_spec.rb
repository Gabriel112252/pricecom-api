require "rails_helper"

RSpec.describe Dashboard::ProductsTimeseries do
  let(:tenant)          { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:other_tenant)    { Tenant.create!(name: "Outra Loja", slug: "outra-loja-#{SecureRandom.hex(4)}") }
  let(:channel_tiktok)  { tenant.channels.create!(name: "TikTok Shop", platform: "tiktok") }
  let(:channel_yampi)   { tenant.channels.create!(name: "Yampi", platform: "yampi") }
  let(:product_a)       { tenant.products.create!(sku: "2080", name: "Protetor Solar Clareador") }
  let(:product_b)       { tenant.products.create!(sku: "0109", name: "Sérum Multicorretivo") }

  def make_order(channel, gross:, ordered_at:, order_type: "sale", **attrs)
    tenant.orders.create!(
      channel: channel, external_id: "order-#{SecureRandom.hex(4)}", order_number: "N#{SecureRandom.hex(3)}",
      order_type: order_type, gross_value: gross, ordered_at: ordered_at, **attrs
    )
  end

  def call(params = {})
    described_class.call(tenant: tenant, params: ActionController::Parameters.new(params))
  end

  it "returns no series when skus is blank" do
    result = call(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601)
    expect(result[:series]).to eq([])
  end

  it "never returns another tenant's product" do
    other_tenant.products.create!(sku: "2080", name: "Protetor de outra loja")

    result = call(skus: [ "2080" ], from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601)

    expect(result[:series]).to eq([])
  end

  describe "daily buckets for matched products" do
    before do
      order_day1 = make_order(channel_tiktok, gross: 118.90, ordered_at: Time.zone.parse("2026-08-10 10:00:00"))
      order_day1.order_items.create!(
        product: product_a, sku: "2080", name: product_a.name, quantity: 2,
        unit_price: 35.04, unit_cost: 17.23,
        discount: 48.82, seller_discount: 42.04, platform_discount: 6.78
      )

      order_day3 = make_order(channel_yampi, gross: 50, ordered_at: Time.zone.parse("2026-08-12 15:00:00"))
      order_day3.order_items.create!(
        product: product_a, sku: "2080", name: product_a.name, quantity: 3,
        unit_price: 20, unit_cost: 10, discount: 10
      )

      order_b = make_order(channel_yampi, gross: 30, ordered_at: Time.zone.parse("2026-08-11 09:00:00"))
      order_b.order_items.create!(
        product: product_b, sku: "0109", name: product_b.name, quantity: 1,
        unit_price: 30, unit_cost: 12, discount: 0
      )
    end

    it "fills every day in the period, zeroing days with no sales, without skipping any date" do
      result = call(skus: [ "2080" ], from: "2026-08-09", to: "2026-08-13")

      series = result[:series].first
      dates = series[:points].map { |p| p[:date] }
      expect(dates).to eq(%w[2026-08-09 2026-08-10 2026-08-11 2026-08-12 2026-08-13])

      by_date = series[:points].index_by { |p| p[:date] }
      expect(by_date["2026-08-09"]).to include(qty_sold: 0.0, revenue: 0.0)
      # tiktok: 2*35.04 + 6.78 = 76.86
      expect(by_date["2026-08-10"]).to include(qty_sold: 2.0, revenue: 76.86)
      expect(by_date["2026-08-11"]).to include(qty_sold: 0.0, revenue: 0.0)
      # yampi: 3*20 - 10 = 50
      expect(by_date["2026-08-12"]).to include(qty_sold: 3.0, revenue: 50.0)
      expect(by_date["2026-08-13"]).to include(qty_sold: 0.0, revenue: 0.0)
    end

    it "returns one series per requested SKU, ordered by SKU, each with its own name" do
      result = call(skus: [ "2080", "0109" ], from: "2026-08-09", to: "2026-08-13")

      expect(result[:series].map { |s| s[:sku] }).to eq(%w[0109 2080])
      expect(result[:series].map { |s| s[:name] }).to eq([ product_b.name, product_a.name ])
    end

    it "applies channel_ids from the first query, restricting qty/revenue to the selected channel" do
      result = call(skus: [ "2080" ], from: "2026-08-09", to: "2026-08-13", channel_ids: [ channel_tiktok.id.to_s ])

      series = result[:series].first
      by_date = series[:points].index_by { |p| p[:date] }
      expect(by_date["2026-08-10"]).to include(qty_sold: 2.0, revenue: 76.86)
      # day 3's sale was on Yampi, excluded by the channel filter
      expect(by_date["2026-08-12"]).to include(qty_sold: 0.0, revenue: 0.0)
    end
  end

  it "excludes gift items and non-revenue-countable orders, like SearchProducts does" do
    unpaid_order = make_order(channel_yampi, gross: 100, ordered_at: Time.zone.parse("2026-08-10 10:00:00"), status: "unpaid")
    unpaid_order.order_items.create!(product: product_a, sku: "2080", name: product_a.name, quantity: 1, unit_price: 100, unit_cost: 10)

    gift_order = make_order(channel_yampi, gross: 0, ordered_at: Time.zone.parse("2026-08-10 10:00:00"))
    gift_order.order_items.create!(product: product_a, sku: "2080", name: product_a.name, quantity: 1, unit_price: 0, unit_cost: 10, is_gift: true)

    result = call(skus: [ "2080" ], from: "2026-08-09", to: "2026-08-11")

    by_date = result[:series].first[:points].index_by { |p| p[:date] }
    expect(by_date["2026-08-10"]).to include(qty_sold: 0.0, revenue: 0.0)
  end
end
