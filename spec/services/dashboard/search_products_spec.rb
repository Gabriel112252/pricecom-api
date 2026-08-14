require "rails_helper"

RSpec.describe Dashboard::SearchProducts do
  let(:tenant)          { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:other_tenant)    { Tenant.create!(name: "Outra Loja", slug: "outra-loja-#{SecureRandom.hex(4)}") }
  let(:channel_tiktok)  { tenant.channels.create!(name: "TikTok Shop", platform: "tiktok") }
  let(:channel_yampi)   { tenant.channels.create!(name: "Yampi", platform: "yampi") }
  let(:product)         { tenant.products.create!(sku: "2080", name: "Protetor Solar Clareador") }

  def make_order(channel, gross:, ordered_at:, order_type: "sale", **attrs)
    tenant.orders.create!(
      channel: channel, external_id: "order-#{SecureRandom.hex(4)}", order_number: "N#{SecureRandom.hex(3)}",
      order_type: order_type, gross_value: gross, ordered_at: ordered_at, **attrs
    )
  end

  def call(params = {})
    described_class.call(tenant: tenant, params: ActionController::Parameters.new(params))
  end

  it "returns no results when q is blank, instead of dumping every product" do
    result = call(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601)
    expect(result[:results]).to eq([])
  end

  it "matches by partial SKU or partial name, case-insensitively" do
    product
    tenant.products.create!(sku: "0109", name: "Sérum Multicorretivo")

    by_sku  = call(q: "208", from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601)
    by_name = call(q: "protetor", from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601)

    expect(by_sku[:results].map { |r| r[:sku] }).to eq([ "2080" ])
    expect(by_name[:results].map { |r| r[:sku] }).to eq([ "2080" ])
  end

  it "never returns another tenant's product" do
    other_tenant.products.create!(sku: "2080-OTHER", name: "Protetor de outra loja")

    result = call(q: "protetor", from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601)

    expect(result[:results].map { |r| r[:sku] }).to eq([])
  end

  describe "aggregates for a matched product" do
    before do
      order_a = make_order(channel_tiktok, gross: 118.90, ordered_at: 1.day.ago)
      order_a.order_items.create!(
        product: product, sku: "2080", name: product.name, quantity: 2,
        unit_price: 35.04, unit_cost: 17.23,
        discount: 48.82, seller_discount: 42.04, platform_discount: 6.78
      )

      order_b = make_order(channel_yampi, gross: 50, ordered_at: 1.day.ago)
      order_b.order_items.create!(
        product: product, sku: "2080", name: product.name, quantity: 3,
        unit_price: 20, unit_cost: 10, discount: 10
      )
    end

    it "sums qty and the TikTok-aware revenue formula across all channels when no channel_ids is given" do
      result = call(q: "2080", from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601)

      row = result[:results].first
      expect(row[:sku]).to eq("2080")
      expect(row[:total_qty_sold]).to eq(5.0) # 2 (tiktok) + 3 (yampi)
      # tiktok: 2*35.04 + 6.78 = 76.86 ; yampi: 3*20 - 10 = 50 => 126.86
      expect(row[:total_revenue]).to eq(126.86)
    end

    it "breaks down qty/revenue/orders_count per channel" do
      result = call(q: "2080", from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601)

      by_channel = result[:results].first[:by_channel].index_by { |c| c[:platform] }
      expect(by_channel["tiktok"]).to include(orders_count: 1, qty_sold: 2.0, revenue: 76.86)
      expect(by_channel["yampi"]).to include(orders_count: 1, qty_sold: 3.0, revenue: 50.0)
    end

    it "restricts qty/revenue to the selected channel when channel_ids is given" do
      result = call(
        q: "2080", from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601,
        channel_ids: [ channel_tiktok.id.to_s ]
      )

      row = result[:results].first
      expect(row[:total_qty_sold]).to eq(2.0)
      expect(row[:total_revenue]).to eq(76.86)
      expect(row[:by_channel].map { |c| c[:platform] }).to eq([ "tiktok" ])
    end

    it "returns zeroed totals for a matched product with no sales in the period" do
      result = call(q: "2080", from: 400.days.ago.to_date.iso8601, to: 390.days.ago.to_date.iso8601)

      row = result[:results].first
      expect(row[:total_qty_sold]).to eq(0.0)
      expect(row[:total_revenue]).to eq(0.0)
      expect(row[:by_channel]).to eq([])
    end
  end

  it "excludes gift items and non-revenue-countable orders, like the Top 10 rankings do" do
    order = make_order(channel_yampi, gross: 100, ordered_at: 1.day.ago, status: "unpaid")
    order.order_items.create!(product: product, sku: "2080", name: product.name, quantity: 1, unit_price: 100, unit_cost: 10)

    gift_order = make_order(channel_yampi, gross: 0, ordered_at: 1.day.ago)
    gift_order.order_items.create!(product: product, sku: "2080", name: product.name, quantity: 1, unit_price: 0, unit_cost: 10, is_gift: true)

    result = call(q: "2080", from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601)

    expect(result[:results].first[:total_qty_sold]).to eq(0.0)
  end

  it "excludes cancelled orders from total_qty_sold/total_revenue, even with order_type sale" do
    order = make_order(channel_yampi, gross: 100, ordered_at: 1.day.ago, status: "cancelled")
    order.order_items.create!(product: product, sku: "2080", name: product.name, quantity: 5, unit_price: 100, unit_cost: 10)

    result = call(q: "2080", from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601)

    expect(result[:results].first[:total_qty_sold]).to eq(0.0)
    expect(result[:results].first[:total_revenue]).to eq(0.0)
  end

  describe "free samples (order_type: sample)" do
    it "excludes sample orders from total_qty_sold/total_revenue/by_channel" do
      sample_order = make_order(channel_tiktok, gross: 0, ordered_at: 1.day.ago, order_type: "sample")
      sample_order.order_items.create!(product: product, sku: "2080", name: product.name, quantity: 4, unit_price: 0, unit_cost: 10)

      result = call(q: "2080", from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601)

      row = result[:results].first
      expect(row[:total_qty_sold]).to eq(0.0)
      expect(row[:total_revenue]).to eq(0.0)
      expect(row[:by_channel]).to eq([])
    end

    it "reports sample_qty_sent separately from real sales, without folding it into total_qty_sold" do
      real_order = make_order(channel_yampi, gross: 50, ordered_at: 1.day.ago)
      real_order.order_items.create!(product: product, sku: "2080", name: product.name, quantity: 3, unit_price: 20, unit_cost: 10, discount: 10)

      sample_order = make_order(channel_tiktok, gross: 0, ordered_at: 1.day.ago, order_type: "sample")
      sample_order.order_items.create!(product: product, sku: "2080", name: product.name, quantity: 4, unit_price: 0, unit_cost: 10)

      result = call(q: "2080", from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601)

      row = result[:results].first
      expect(row[:total_qty_sold]).to eq(3.0)
      expect(row[:sample_qty_sent]).to eq(4.0)
    end

    it "restricts sample_qty_sent to the selected channel when channel_ids is given" do
      make_order(channel_tiktok, gross: 0, ordered_at: 1.day.ago, order_type: "sample").order_items.create!(
        product: product, sku: "2080", name: product.name, quantity: 4, unit_price: 0, unit_cost: 10
      )
      make_order(channel_yampi, gross: 0, ordered_at: 1.day.ago, order_type: "sample").order_items.create!(
        product: product, sku: "2080", name: product.name, quantity: 2, unit_price: 0, unit_cost: 10
      )

      result = call(
        q: "2080", from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601,
        channel_ids: [ channel_tiktok.id.to_s ]
      )

      expect(result[:results].first[:sample_qty_sent]).to eq(4.0)
    end

    it "returns sample_qty_sent 0.0 for a product with no samples" do
      make_order(channel_yampi, gross: 50, ordered_at: 1.day.ago).order_items.create!(
        product: product, sku: "2080", name: product.name, quantity: 1, unit_price: 50, unit_cost: 10
      )

      result = call(q: "2080", from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601)

      expect(result[:results].first[:sample_qty_sent]).to eq(0.0)
    end
  end
end
