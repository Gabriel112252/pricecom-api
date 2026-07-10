require "rails_helper"

RSpec.describe Dashboard::BuildSummary do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:channel_a) { tenant.channels.create!(name: "Yampi", platform: "yampi") }
  let(:channel_b) { tenant.channels.create!(name: "Shopify", platform: "shopify") }

  def make_order(channel, gross:, margin:, ordered_at:, refund: 0)
    tenant.orders.create!(
      channel: channel, external_id: "order-#{SecureRandom.hex(4)}", order_number: "N1",
      order_type: "sale", gross_value: gross, margin: margin, refund_amount: refund, ordered_at: ordered_at
    )
  end

  def make_conflict(conflict_type:, difference:, status: "open", created_at: Time.current, resolved_at: nil)
    tenant.audit_conflicts.create!(
      conflict_type: conflict_type, severity: "high", status: status,
      difference: difference, created_at: created_at, resolved_at: resolved_at
    )
  end

  describe "granularity" do
    it "returns hour granularity for a 1-day window" do
      today = Date.current
      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: today.iso8601, to: today.iso8601))
      expect(result[:granularity]).to eq("hour")
    end

    it "returns day granularity for a multi-day window" do
      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 29.days.ago.to_date.iso8601, to: Date.current.iso8601))
      expect(result[:granularity]).to eq("day")
    end
  end

  describe "revenue and orders totals" do
    before do
      make_order(channel_a, gross: 100, margin: 30, ordered_at: 1.day.ago)
      make_order(channel_a, gross: 200, margin: 40, ordered_at: 1.day.ago, refund: 20)
    end

    it "computes gross, net, aov and vs_previous_pct against the prior period" do
      make_order(channel_a, gross: 100, margin: 10, ordered_at: 32.days.ago) # falls in the "previous period" for a 30-day window

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 29.days.ago.to_date.iso8601, to: Date.current.iso8601))

      expect(result[:revenue][:gross]).to eq(300.0)
      expect(result[:revenue][:net]).to eq(280.0)
      expect(result[:orders][:count]).to eq(2)
      expect(result[:orders][:aov]).to eq(150.0)
      expect(result[:orders][:vs_previous_period_pct]).to eq(100.0) # 2 orders vs 1 previously
    end

    it "filters by channel_ids when provided" do
      make_order(channel_b, gross: 500, margin: 50, ordered_at: 1.day.ago)

      result = described_class.call(
        tenant: tenant,
        params: ActionController::Parameters.new(
          from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601, channel_ids: [ channel_a.id.to_s ]
        )
      )

      expect(result[:revenue][:gross]).to eq(300.0)
      expect(result[:revenue][:by_channel].keys).to eq([ "Yampi" ])
    end

    it "returns a per-channel, per-bucket order volume series" do
      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

      series = result[:orders][:by_channel_series]
      expect(series.sum { |row| row[:count] }).to eq(2)
      expect(series.map { |row| row[:channel] }.uniq).to eq([ "Yampi" ])
    end

    it "returns a per-channel, per-bucket revenue series" do
      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

      series = result[:revenue][:by_channel_series]
      expect(series.sum { |row| row[:gross] }).to eq(300.0)
      expect(series.map { |row| row[:channel] }.uniq).to eq([ "Yampi" ])
    end

    it "computes average ticket per channel" do
      make_order(channel_b, gross: 500, margin: 50, ordered_at: 1.day.ago)

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

      expect(result[:orders][:aov_by_channel]).to eq({ "Yampi" => 150.0, "Shopify" => 500.0 })
    end
  end

  describe "conflicts" do
    it "sums the absolute value of open financial conflicts as value_at_risk, ignoring resolved ones and non-financial types" do
      make_conflict(conflict_type: "nf_discount_mismatch", difference: -15.5)
      make_conflict(conflict_type: "settlement_amount_mismatch", difference: 4.3)
      make_conflict(conflict_type: "missing_cost", difference: 999) # not a financial conflict type
      make_conflict(conflict_type: "nf_freight_mismatch", difference: 10, status: "resolved", resolved_at: Time.current)

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new)

      expect(result[:conflicts][:value_at_risk]).to eq(19.8)
    end

    it "reports the age in days of the oldest open conflict, ignoring resolved ones" do
      make_conflict(conflict_type: "missing_settlement", difference: 1, created_at: 10.days.ago)
      make_conflict(conflict_type: "missing_settlement", difference: 1, created_at: 1.day.ago)
      make_conflict(conflict_type: "missing_settlement", difference: 1, created_at: 40.days.ago, status: "resolved", resolved_at: Time.current)

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new)

      expect(result[:conflicts][:oldest_open_days]).to eq(10)
    end

    it "buckets opened vs resolved conflicts by week for the last 8 weeks" do
      make_conflict(conflict_type: "missing_settlement", difference: 1, created_at: 3.weeks.ago)
      make_conflict(conflict_type: "missing_settlement", difference: 1, created_at: 3.weeks.ago, status: "resolved", resolved_at: 2.weeks.ago)

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new)

      trend = result[:conflicts][:resolution_trend]
      expect(trend.size).to eq(8)
      expect(trend.sum { |w| w[:opened] }).to eq(2)
      expect(trend.sum { |w| w[:resolved] }).to eq(1)
    end

    it "is not scoped by the selected date range — reflects current outstanding state" do
      make_conflict(conflict_type: "missing_settlement", difference: 50, created_at: 90.days.ago)

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: Date.current.iso8601, to: Date.current.iso8601))

      expect(result[:conflicts][:value_at_risk]).to eq(50.0)
    end
  end

  describe "top products and turnover, including kit explosion" do
    let(:leaf) { tenant.products.create!(sku: "LEAF-1", name: "Componente", cost_price: 5) }
    let(:kit)  { tenant.products.create!(sku: "KIT-1", name: "Kit", is_kit: true, cost_price: 0) }

    before do
      kit.kit_components.create!(component_product: leaf, quantity: 2)
    end

    it "ranks top_products_by_revenue by revenue instead of margin" do
      order = make_order(channel_a, gross: 1000, margin: 100, ordered_at: 1.day.ago)
      order.order_items.create!(product: leaf, sku: leaf.sku, name: leaf.name, quantity: 1, unit_price: 1000, unit_cost: 900)

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

      expect(result[:top_products_by_revenue].first).to include(sku: "LEAF-1", revenue: 1000.0)
    end

    it "explodes kit sales into real component quantities and flags kit-only sellers" do
      order = make_order(channel_a, gross: 300, margin: 30, ordered_at: 1.day.ago)
      order.order_items.create!(product: kit, sku: kit.sku, name: kit.name, quantity: 3, unit_price: 100, unit_cost: 60)

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

      leaf_summary = result[:product_turnover_summary].find { |p| p[:sku] == "LEAF-1" }
      expect(leaf_summary[:direct_qty]).to eq(0.0)
      expect(leaf_summary[:kit_qty]).to eq(6.0) # 3 kits x 2 components each
      expect(leaf_summary[:kit_only]).to eq(true)
    end
  end
end
