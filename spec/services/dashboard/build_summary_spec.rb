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
      expect(result[:orders][:aov]).to eq(140.0)
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
      expect(series.sum { |row| row[:gross] }).to eq(280.0)
      expect(series.map { |row| row[:channel] }.uniq).to eq([ "Yampi" ])
    end

    it "computes average ticket per channel" do
      make_order(channel_b, gross: 500, margin: 50, ordered_at: 1.day.ago)

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

      expect(result[:orders][:aov_by_channel]).to eq({ "Yampi" => 140.0, "Shopify" => 500.0 })
    end
  end

  describe "executive financial payload" do
    it "exposes executive KPIs with net revenue, discounts and financial coverage" do
      order = make_order(channel_a, gross: 100, margin: 0, ordered_at: 1.day.ago)
      product = tenant.products.create!(sku: "SKU-1", name: "Produto", cost_price: 30)
      order.update!(discount: 15, freight: 8, commission: 4, operational_cost: 2)
      order.order_items.create!(product: product, sku: product.sku, name: product.name, quantity: 1, unit_price: 100, unit_cost: 30)

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

      expect(result[:kpis]).to include(
        gross_revenue: 100.0,
        net_revenue: 85.0,
        average_ticket: 85.0,
        discounts_total: 15.0,
        contribution_margin: 48.24,
        contribution_margin_available: true,
        financial_coverage_percentage: 100.0
      )
      expect(result[:financial_composition][:result]).to include(value: 41.0, available: true, status: "available")
    end

    it "does not expose contribution margin as definitive when order cost is incomplete" do
      order = make_order(channel_a, gross: 100, margin: 0, ordered_at: 1.day.ago)
      order.update!(discount: 20)
      order.order_items.create!(sku: "MISSING-COST", name: "Produto sem custo", quantity: 1, unit_price: 100, unit_cost: nil)

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

      expect(result[:kpis][:net_revenue]).to eq(80.0)
      expect(result[:kpis][:contribution_margin_available]).to eq(false)
      expect(result[:kpis][:contribution_margin]).to be_nil
      expect(result[:financial][:profit_available]).to eq(false)
      expect(result[:financial][:profit]).to be_nil
      expect(result[:financial_composition][:result]).to include(value: nil, available: false, status: "incomplete")
      expect(result[:data_quality]).to include(
        missing_cost_orders_count: 1,
        complete_orders_count: 0,
        incomplete_orders_count: 1,
        financial_status: "incomplete"
      )
    end
  end

  describe "revenue breakdown card" do
    it "closes the accounting equation including canceled orders and freight/taxes" do
      order = make_order(channel_a, gross: 200, margin: 0, ordered_at: 1.day.ago, refund: 10)
      order.update!(discount: 20, freight: 15)
      make_order(channel_a, gross: 80, margin: 0, ordered_at: 1.day.ago).update!(status: "cancelado")

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

      breakdown = result[:revenue_breakdown]
      expect(breakdown).to include(
        gross_revenue: 280.0,
        discounts: 20.0,
        cancellations_and_refunds: 90.0,
        freight: 15.0,
        taxes: 0.0,
        freight_and_taxes: 15.0,
        net_revenue: 155.0
      )
      expect(breakdown[:gross_revenue] - breakdown[:discounts] - breakdown[:cancellations_and_refunds] - breakdown[:freight_and_taxes])
        .to eq(breakdown[:net_revenue])
      # O net histórico (séries, AOV, share) segue sem descontar frete/imposto.
      expect(result[:kpis][:net_revenue]).to eq(170.0)
    end

    it "counts canceled orders regardless of status casing" do
      make_order(channel_a, gross: 80, margin: 0, ordered_at: 1.day.ago).update!(status: "CANCELLED")
      make_order(channel_a, gross: 20, margin: 0, ordered_at: 1.day.ago).update!(status: "cancelled")

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

      expect(result[:revenue_breakdown][:cancellations_and_refunds]).to eq(100.0)
      expect(result[:revenue_breakdown][:gross_revenue]).to eq(100.0)
      # Nenhum dos dois entra nos agregados de pedidos válidos.
      expect(result[:kpis][:gross_revenue]).to eq(0.0)
      expect(result[:kpis][:orders_count]).to eq(0)
    end

    it "compares the breakdown net against the previous period" do
      make_order(channel_a, gross: 100, margin: 0, ordered_at: 1.day.ago)
      make_order(channel_a, gross: 50, margin: 0, ordered_at: 10.days.ago)

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

      expect(result[:revenue_breakdown][:net_vs_previous_pct]).to eq(100.0)
    end
  end

  describe "regional and coupon payload" do
    it "summarizes orders by Brazilian state and coupon usage" do
      sp_order = make_order(channel_a, gross: 120, margin: 0, ordered_at: 1.day.ago)
      sp_order.update!(state: "SP", discount: 20, coupon_code: "BEMVINDO", coupon_discount: 20)
      make_order(channel_a, gross: 80, margin: 0, ordered_at: 1.day.ago).update!(state: "São Paulo")
      make_order(channel_b, gross: 60, margin: 0, ordered_at: 1.day.ago).update!(state: "RJ", discount: 10, coupon_code: "BEMVINDO", coupon_discount: 10)
      make_order(channel_b, gross: 40, margin: 0, ordered_at: 1.day.ago).update!(state: "MG", discount: 5, coupon_code: "VIP", coupon_discount: 5)

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

      expect(result[:regional_sales][:top_state]).to include(state: "SP", orders_count: 2)
      expect(result[:regional_sales][:states].find { |state| state[:state] == "RJ" }).to include(orders_count: 1, net_revenue: 50.0)
      expect(result[:coupons]).to include(total_discount: 35.0, orders_count: 3)
      expect(result[:coupons][:top_coupons].first).to include(code: "BEMVINDO", orders_count: 2, discount_total: 30.0)
      expect(result[:kpis]).to include(coupon_discount_total: 35.0, coupon_orders_count: 3, top_region_state: "SP")
    end

    it "surfaces uncoded discounts without inventing coupon rankings" do
      make_order(channel_a, gross: 120, margin: 0, ordered_at: 1.day.ago).update!(state: "SP", discount: 20)

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

      expect(result[:coupons]).to include(
        has_coupon_codes: false,
        display_discount_total: 20.0,
        uncoded_discount_total: 20.0,
        uncoded_discount_orders_count: 1,
        commercial_discount_total: 20.0,
        commercial_discount_orders_count: 1,
        top_coupons: []
      )
      expect(result[:kpis]).to include(coupon_discount_total: 20.0, coupon_orders_count: 1)
    end

    it "separates shipping subsidy when real freight is greater than charged freight" do
      make_order(channel_a, gross: 120, margin: 0, ordered_at: 1.day.ago)
        .update!(state: "SP", discount: 20, freight: 8, real_freight_cost: 18)

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

      expect(result[:coupons]).to include(
        display_discount_total: 30.0,
        commercial_discount_total: 20.0,
        shipping_subsidy_total: 10.0,
        shipping_subsidy_orders_count: 1
      )
      expect(result[:coupons][:breakdown].map { |row| row[:key] }).to include("commercial_discount", "shipping_subsidy")
      expect(result[:kpis]).to include(coupon_discount_total: 30.0, shipping_subsidy_total: 10.0)
    end

    it "ranks item-level discounts by product with pct over the list price (unit_price is net of discount)" do
      order = make_order(channel_a, gross: 200, margin: 0, ordered_at: 1.day.ago)
      order.order_items.create!(sku: "SKU-A", name: "Produto A", quantity: 2, unit_price: 50, discount: 25)
      order.order_items.create!(sku: "SKU-B", name: "Produto B", quantity: 1, unit_price: 100, discount: 10)

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

      by_product = result[:coupons][:by_product]
      # % sobre o preço de tabela (líquido + desconto): 25/125 e 10/110.
      expect(by_product.first).to include(sku: "SKU-A", discount_total: 25.0, discount_pct: 20.0, orders_count: 1)
      expect(by_product.second).to include(sku: "SKU-B", discount_total: 10.0, discount_pct: 9.09)
    end

    it "keeps discount_pct below 100% when the discount exceeds the net unit price" do
      # Caso real de produção (SKU 2080_2): unit_price líquido 35.01 com
      # desconto 37.92 — sobre o líquido daria 108%; sobre o de tabela, 52%.
      order = make_order(channel_a, gross: 35.01, margin: 0, ordered_at: 1.day.ago)
      order.order_items.create!(sku: "2080_2", name: "Produto", quantity: 1, unit_price: 35.01, discount: 37.92)

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

      row = result[:coupons][:by_product].first
      expect(row).to include(sku: "2080_2", discount_total: 37.92, discount_pct: 52.0)
      expect(row[:discount_pct]).to be < 100
    end
  end

  describe "discount ticket and product exposure" do
    it "summarizes discount incidence and average discount among discounted orders" do
      make_order(channel_a, gross: 100, margin: 0, ordered_at: 1.day.ago).update!(discount: 10)
      make_order(channel_a, gross: 100, margin: 0, ordered_at: 1.day.ago).update!(discount: 30)
      make_order(channel_a, gross: 100, margin: 0, ordered_at: 1.day.ago)

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

      expect(result[:discount_ticket_summary]).to eq(
        discounted_orders_count: 2,
        total_orders_count: 3,
        discount_rate_pct: 66.67,
        avg_discount_per_order: 20.0
      )
    end

    it "ranks products by orders with discount and keeps exposure_pct at most 100%" do
      # SKU-LOW: 1 pedido com desconto entre 4 (baixa exposição, 25%);
      # SKU-HIGH: 2 de 2 (100%).
      4.times do |i|
        order = make_order(channel_a, gross: 100, margin: 0, ordered_at: 1.day.ago)
        order.update!(discount: 15) if i.zero?
        order.order_items.create!(sku: "SKU-LOW", name: "Produto Low", quantity: 1, unit_price: 100)
      end
      2.times do
        order = make_order(channel_a, gross: 100, margin: 0, ordered_at: 1.day.ago)
        order.update!(discount: 15)
        order.order_items.create!(sku: "SKU-HIGH", name: "Produto High", quantity: 1, unit_price: 100)
      end

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

      exposure = result[:product_discount_exposure]
      expect(exposure.first).to include(
        sku: "SKU-HIGH", discounted_orders_count: 2, total_orders_count: 2, exposure_pct: 100.0
      )
      expect(exposure.second).to include(
        sku: "SKU-LOW", discounted_orders_count: 1, total_orders_count: 4, exposure_pct: 25.0
      )
      expect(exposure).to all(satisfy { |row| row[:exposure_pct] <= 100.0 })
    end
  end

  describe "non-revenue statuses (unpaid / status_unknown)" do
    let(:tiktok_channel) { tenant.channels.create!(name: "TikTok Shop", platform: "tiktok") }

    it "excludes unpaid and status_unknown orders from revenue, order count and top products" do
      make_order(channel_a, gross: 100, margin: 30, ordered_at: 1.day.ago)
      product = tenant.products.create!(sku: "SKU-U", name: "Produto", cost_price: 10)

      unpaid = make_order(tiktok_channel, gross: 500, margin: 0, ordered_at: 1.day.ago)
      unpaid.update!(status: "unpaid")
      unpaid.order_items.create!(product: product, sku: product.sku, name: product.name, quantity: 3, unit_price: 100, unit_cost: 10)

      unknown = make_order(tiktok_channel, gross: 300, margin: 0, ordered_at: 1.day.ago)
      unknown.update!(status: "status_unknown")

      verbatim = make_order(tiktok_channel, gross: 200, margin: 0, ordered_at: 1.day.ago)
      verbatim.update_column(:status, "UNPAID") # legado pré-normalização

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

      expect(result[:revenue][:gross]).to eq(100.0)
      expect(result[:orders][:count]).to eq(1)
      expect(result[:top_products_by_revenue]).to eq([])
      expect(result[:product_turnover_summary]).to eq([])
    end

    it "exposes how many orders (and how much) were excluded, for the UI transparency badge" do
      make_order(channel_a, gross: 100, margin: 30, ordered_at: 1.day.ago)
      make_order(tiktok_channel, gross: 500, margin: 0, ordered_at: 1.day.ago).update!(status: "unpaid")
      make_order(tiktok_channel, gross: 300, margin: 0, ordered_at: 1.day.ago).update!(status: "status_unknown")
      # Fora do período — não entra no selo
      make_order(tiktok_channel, gross: 900, margin: 0, ordered_at: 60.days.ago).update!(status: "unpaid")

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

      expect(result[:kpis]).to include(
        non_revenue_excluded_count: 2,
        non_revenue_excluded_amount: 800.0
      )
    end

    it "scopes the exclusion badge to the channel filter and zeroes it when nothing was excluded" do
      make_order(tiktok_channel, gross: 500, margin: 0, ordered_at: 1.day.ago).update!(status: "unpaid")

      tiktok_only = described_class.call(
        tenant: tenant,
        params: ActionController::Parameters.new(
          from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601, channel_ids: [ tiktok_channel.id.to_s ]
        )
      )
      yampi_only = described_class.call(
        tenant: tenant,
        params: ActionController::Parameters.new(
          from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601, channel_ids: [ channel_a.id.to_s ]
        )
      )

      expect(tiktok_only[:kpis]).to include(non_revenue_excluded_count: 1, non_revenue_excluded_amount: 500.0)
      expect(yampi_only[:kpis]).to include(non_revenue_excluded_count: 0, non_revenue_excluded_amount: 0.0)
    end
  end

  describe "cart abandonment" do
    let(:tiktok_channel) { tenant.channels.create!(name: "TikTok Shop", platform: "tiktok") }

    def make_cart(channel, total:, status: "abandoned", abandoned_at: 1.day.ago)
      tenant.carts.create!(
        channel: channel, external_id: "cart-#{SecureRandom.hex(4)}",
        total: total, status: status, abandoned_at: abandoned_at
      )
    end

    it "keeps the yampi_checkout mode by default and counts only the filtered channel's carts" do
      make_cart(channel_a, total: 50)
      make_cart(tiktok_channel, total: 80)

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

      expect(result[:cart_abandonment][:mode]).to eq("yampi_checkout")
      expect(result[:cart_abandonment][:total_count]).to eq(2)
    end

    it "switches to tiktok_unpaid mode when the channel filter is TikTok-only" do
      make_cart(channel_a, total: 50)
      make_cart(tiktok_channel, total: 80)
      make_cart(tiktok_channel, total: 30, status: "converted")

      result = described_class.call(
        tenant: tenant,
        params: ActionController::Parameters.new(
          from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601, channel_ids: [ tiktok_channel.id.to_s ]
        )
      )

      cart_abandonment = result[:cart_abandonment]
      expect(cart_abandonment[:mode]).to eq("tiktok_unpaid")
      expect(cart_abandonment[:total_count]).to eq(2)
      expect(cart_abandonment[:still_abandoned]).to eq(count: 1, value: 80.0)
      expect(cart_abandonment[:recovered]).to eq(count: 1, value: 30.0)
    end

    it "keeps yampi_checkout mode on a mixed channel selection" do
      result = described_class.call(
        tenant: tenant,
        params: ActionController::Parameters.new(
          from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601,
          channel_ids: [ channel_a.id.to_s, tiktok_channel.id.to_s ]
        )
      )

      expect(result[:cart_abandonment][:mode]).to eq("yampi_checkout")
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
