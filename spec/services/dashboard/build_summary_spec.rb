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

  describe "gateway fees (Pagar.me)" do
    let(:pagarme_source) do
      tenant.financial_sources.create!(
        provider: "pagarme", name: "Pagar.me", source_type: "gateway", status: "active"
      )
    end

    def enable_payment_reconciliation!
      tenant.data_source_configs.create!(data_type: "payment_reconciliation", source: "pagarme", enabled: true)
    end

    def make_settlement_item(channel:, fee_amount:, transaction_date:, external_id: "item-#{SecureRandom.hex(4)}")
      settlement = pagarme_source.financial_settlements.create!(
        tenant: tenant, channel: channel, external_id: "settle-#{SecureRandom.hex(4)}",
        period_start: transaction_date.to_date, period_end: transaction_date.to_date, status: "paid"
      )
      settlement.financial_settlement_items.create!(
        tenant: tenant, external_id: external_id, transaction_type: "sale",
        gross_amount: 100, fee_amount: fee_amount, net_amount: 90, transaction_date: transaction_date
      )
    end

    it "is zero and not_configured when payment_reconciliation isn't set to pagarme" do
      make_order(channel_a, gross: 100, margin: 0, ordered_at: 1.day.ago)
      make_settlement_item(channel: channel_a, fee_amount: 10, transaction_date: 1.day.ago)

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

      expect(result[:financial][:gateway_fees]).to eq(0.0)
      expect(result[:financial_composition][:gateway_fees]).to include(available: false, status: "not_configured")
      expect(result[:financial][:gateway_fee_avg_per_order]).to be_nil
    end

    it "sums FinancialSettlementItem.fee_amount within the period, deducts it from result, and respects the channel filter" do
      enable_payment_reconciliation!
      order = make_order(channel_a, gross: 100, margin: 0, ordered_at: 1.day.ago)
      product = tenant.products.create!(sku: "SKU-GW", name: "Produto", cost_price: 1)
      order.order_items.create!(product: product, sku: product.sku, name: product.name, quantity: 1, unit_price: 100, unit_cost: 1)
      make_settlement_item(channel: channel_a, fee_amount: 6.5, transaction_date: 1.day.ago)
      make_settlement_item(channel: channel_a, fee_amount: 3.5, transaction_date: 20.days.ago) # fora do período de 6 dias

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

      expect(result[:financial][:gateway_fees]).to eq(6.5)
      expect(result[:financial_composition][:gateway_fees]).to include(value: 6.5, available: true, status: "available")
      expect(result[:financial_composition][:result][:value]).to eq(92.5) # 100 - 1 de CMV - 6.5 de taxa

      filtered = described_class.call(
        tenant: tenant,
        params: ActionController::Parameters.new(
          from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601, channel_ids: [ channel_b.id.to_s ]
        )
      )
      expect(filtered[:financial][:gateway_fees]).to eq(0.0)
    end

    it "does not double count with FinancialReceivable (same payable, two records)" do
      enable_payment_reconciliation!
      make_order(channel_a, gross: 100, margin: 0, ordered_at: 1.day.ago)
      item = make_settlement_item(channel: channel_a, fee_amount: 10, transaction_date: 1.day.ago)
      tenant.financial_receivables.create!(
        financial_source: pagarme_source, financial_settlement_item: item, payable_id: "pay-1",
        status: "paid", amount: 100, fee_amount: 10, net_amount: 90
      )

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

      expect(result[:financial][:gateway_fees]).to eq(10.0)
    end

    it "computes gateway_fee_avg_per_order over Yampi orders regardless of the active channel filter" do
      enable_payment_reconciliation!
      make_order(channel_a, gross: 100, margin: 0, ordered_at: 1.day.ago)
      make_order(channel_a, gross: 100, margin: 0, ordered_at: 1.day.ago)
      make_order(channel_b, gross: 500, margin: 0, ordered_at: 1.day.ago) # Shopify — não entra no denominador
      make_settlement_item(channel: channel_a, fee_amount: 15, transaction_date: 1.day.ago)

      result = described_class.call(
        tenant: tenant,
        params: ActionController::Parameters.new(
          from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601, channel_ids: [ channel_b.id.to_s ]
        )
      )

      # 15 de taxa / 2 pedidos Yampi — mesmo com o filtro em Shopify.
      expect(result[:financial][:gateway_fee_avg_per_order]).to eq(7.5)
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

    describe "per-platform discount breakdown (Yampi coupons vs TikTok aggregate)" do
      let(:channel_tiktok) { tenant.channels.create!(name: "TikTok Shop", platform: "tiktok") }

      before do
        make_order(channel_a, gross: 120, margin: 0, ordered_at: 1.day.ago)
          .update!(discount: 20, coupon_code: "BEMVINDO", coupon_discount: 20)
        make_order(channel_a, gross: 80, margin: 0, ordered_at: 1.day.ago)
          .update!(discount: 5, coupon_code: "VIP", coupon_discount: 5)
        make_order(channel_tiktok, gross: 200, margin: 0, ordered_at: 1.day.ago).update!(discount: 30)
        make_order(channel_tiktok, gross: 100, margin: 0, ordered_at: 1.day.ago)
      end

      def summary_for(channel_ids: nil)
        params = { from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601 }
        params[:channel_ids] = channel_ids if channel_ids
        described_class.call(tenant: tenant, params: ActionController::Parameters.new(**params))
      end

      it "exposes both blocks when no channel filter is applied" do
        result = summary_for

        yampi = result[:coupons][:discount_breakdown_yampi]
        expect(yampi).to include(available: true, orders_count: 2, discount_total: 25.0)
        expect(yampi[:top_coupons].map { |row| row[:code] }).to eq(%w[BEMVINDO VIP])
        expect(result[:coupons][:discount_breakdown_tiktok]).to include(
          available: true, orders_count: 2, discount_total: 0.0,
          seller_discount_total: 0.0, platform_subsidy_total: 0.0
        )
      end

      it "marks the TikTok block unavailable under a Yampi-only filter" do
        result = summary_for(channel_ids: [ channel_a.id.to_s ])

        expect(result[:coupons][:discount_breakdown_yampi]).to include(available: true, orders_count: 2, discount_total: 25.0)
        expect(result[:coupons][:discount_breakdown_tiktok]).to include(
          available: false, orders_count: 0, discount_total: 0.0
        )
      end

      it "marks the Yampi block unavailable under a TikTok-only filter" do
        result = summary_for(channel_ids: [ channel_tiktok.id.to_s ])

        yampi = result[:coupons][:discount_breakdown_yampi]
        expect(yampi).to include(available: false, orders_count: 0, discount_total: 0.0)
        expect(yampi[:top_coupons]).to eq([])
        expect(result[:coupons][:discount_breakdown_tiktok]).to include(
          available: true, orders_count: 2, discount_total: 0.0
        )
      end
    end

    describe "TikTok financial discount and fee breakdown" do
      let(:channel_tiktok) { tenant.channels.create!(name: "TikTok Shop", platform: "tiktok") }

      def tiktok_summary
        described_class.call(
          tenant: tenant,
          params: ActionController::Parameters.new(
            from: 6.days.ago.to_date.iso8601,
            to: Date.current.iso8601,
            channel_ids: [ channel_tiktok.id.to_s ]
          )
        )
      end

      it "separates seller discount, platform subsidy and financial fees for the real order" do
        make_order(channel_tiktok, gross: 36.46, margin: 0, ordered_at: 1.day.ago).update!(
          discount: 18.52,
          seller_discount: 0,
          platform_discount: 0,
          revenue_amount: 29.90,
          settlement_amount: 17.83,
          fee_and_tax_amount: 12.07,
          platform_commission_amount: 1.79,
          affiliate_commission_amount: 4.49,
          item_fee_amount: 4.00,
          service_fee_amount: 1.79,
          shipping_cost_amount: 0,
          financial_synced_at: Time.current
        )

        result = tiktok_summary
        discount = result[:coupons][:discount_breakdown_tiktok]
        financial = result[:financial][:tiktok_financial_breakdown]

        expect(result[:coupons]).to include(
          commercial_discount_total: 0.0,
          uncoded_discount_total: 0.0
        )
        expect(discount).to include(
          available: true,
          orders_count: 1,
          financial_synced_orders_count: 1,
          financial_coverage_percentage: 100.0,
          reference_price_total: 36.46,
          effective_revenue_total: 29.90,
          buyer_paid_product_total: 17.94,
          seller_discount_total: 6.56,
          seller_discount_orders_count: 1,
          platform_subsidy_total: 11.96,
          platform_subsidy_orders_count: 1,
          discount_total: 6.56
        )
        expect(financial).to include(
          available: true,
          orders_count: 1,
          synced_orders_count: 1,
          coverage_percentage: 100.0,
          revenue_amount_total: 29.90,
          settlement_amount_total: 17.83,
          fee_and_tax_amount_total: 12.07,
          platform_commission_total: 1.79,
          affiliate_commission_total: 4.49,
          item_fee_total: 4.00,
          service_fee_total: 1.79,
          shipping_cost_total: 0.0,
          other_fees_total: 0.0
        )
      end

      it "prioritizes populated seller and platform discount columns" do
        make_order(channel_tiktok, gross: 50, margin: 0, ordered_at: 1.day.ago).update!(
          discount: 7,
          seller_discount: 3,
          platform_discount: 4,
          revenue_amount: 47,
          settlement_amount: 47,
          fee_and_tax_amount: 0,
          financial_synced_at: Time.current
        )

        discount = tiktok_summary[:coupons][:discount_breakdown_tiktok]

        expect(discount).to include(seller_discount_total: 3.0, platform_subsidy_total: 4.0)
      end

      it "does not let an unsynchronized order reduce buyer paid product total" do
        make_order(channel_tiktok, gross: 36.46, margin: 0, ordered_at: 1.day.ago).update!(
          discount: 18.52,
          seller_discount: 0,
          platform_discount: 0,
          revenue_amount: 29.90,
          settlement_amount: 17.83,
          fee_and_tax_amount: 12.07,
          financial_synced_at: Time.current
        )
        make_order(channel_tiktok, gross: 100, margin: 0, ordered_at: 1.day.ago).update!(
          discount: 20,
          platform_discount: 20,
          revenue_amount: 80,
          financial_synced_at: nil
        )

        discount = tiktok_summary[:coupons][:discount_breakdown_tiktok]

        expect(discount[:buyer_paid_product_total]).to eq(17.94)
        expect(discount[:platform_subsidy_total]).to eq(31.96)
      end

      it "keeps coverage at zero without dividing by zero" do
        financial = tiktok_summary[:financial][:tiktok_financial_breakdown]

        expect(financial).to include(
          available: true,
          orders_count: 0,
          synced_orders_count: 0,
          coverage_percentage: 0
        )
      end

      it "respects the channel filter for TikTok financial values" do
        make_order(channel_tiktok, gross: 36.46, margin: 0, ordered_at: 1.day.ago).update!(
          revenue_amount: 29.90,
          settlement_amount: 17.83,
          fee_and_tax_amount: 12.07,
          financial_synced_at: Time.current
        )

        filtered = described_class.call(
          tenant: tenant,
          params: ActionController::Parameters.new(
            from: 6.days.ago.to_date.iso8601,
            to: Date.current.iso8601,
            channel_ids: [ channel_a.id.to_s ]
          )
        )

        expect(filtered[:financial][:tiktok_financial_breakdown]).to include(
          available: false,
          orders_count: 0,
          synced_orders_count: 0,
          coverage_percentage: 0
        )
      end
    end

    describe "TikTok real profit, coverage and consolidated financial view" do
      let(:channel_tiktok) { tenant.channels.create!(name: "TikTok Shop", platform: "tiktok") }

      def tiktok_summary
        described_class.call(
          tenant: tenant,
          params: ActionController::Parameters.new(
            from: 6.days.ago.to_date.iso8601,
            to: Date.current.iso8601,
            channel_ids: [ channel_tiktok.id.to_s ]
          )
        )
      end

      it "computes real profit as settlement minus product cost, weighted by revenue for the margin" do
        order = make_order(channel_tiktok, gross: 36.46, margin: 0, ordered_at: 1.day.ago)
        order.update!(revenue_amount: 29.90, settlement_amount: 17.83, fee_and_tax_amount: 12.07, cost_price: 5.83, financial_synced_at: Time.current)
        product = tenant.products.create!(sku: "SKU-TK", name: "Produto TikTok", cost_price: 5.83)
        order.order_items.create!(product: product, sku: product.sku, name: product.name, quantity: 1, unit_price: 29.90, unit_cost: 5.83)

        financial = tiktok_summary[:financial][:tiktok_financial_breakdown]

        expect(financial[:real_profit_total]).to eq(12.0)
        expect(financial[:real_margin_pct]).to eq(40.13)
        expect(financial[:real_profit_available]).to eq(true)
      end

      it "hides real profit and margin when product cost coverage is incomplete, without hiding raw settlement totals" do
        order = make_order(channel_tiktok, gross: 36.46, margin: 0, ordered_at: 1.day.ago)
        order.update!(revenue_amount: 29.90, settlement_amount: 17.83, fee_and_tax_amount: 12.07, financial_synced_at: Time.current)
        order.order_items.create!(sku: "NO-COST", name: "Sem custo", quantity: 1, unit_price: 29.90, unit_cost: nil)

        financial = tiktok_summary[:financial][:tiktok_financial_breakdown]

        expect(financial[:real_profit_available]).to eq(false)
        expect(financial[:real_profit_total]).to be_nil
        expect(financial[:real_margin_pct]).to be_nil
        expect(financial[:settlement_amount_total]).to eq(17.83)
        expect(financial[:revenue_amount_total]).to eq(29.90)
      end

      it "returns margin as nil (not zero) when a fully refunded order has zero revenue" do
        order = make_order(channel_tiktok, gross: 36.46, margin: 0, ordered_at: 1.day.ago)
        order.update!(revenue_amount: 0, settlement_amount: 0, fee_and_tax_amount: 0, cost_price: 0, financial_synced_at: Time.current)
        order.order_items.create!(sku: "SKU-REFUND", name: "Estornado", quantity: 1, unit_price: 0, unit_cost: 0)

        financial = tiktok_summary[:financial][:tiktok_financial_breakdown]

        expect(financial[:real_margin_pct]).to be_nil
        expect(financial[:revenue_amount_total]).to eq(0.0)
        expect(financial[:settlement_amount_total]).to eq(0.0)
      end

      it "exposes an explicit 'other adjustments' reconciliation line instead of folding discrepancies into another category" do
        order = make_order(channel_tiktok, gross: 50, margin: 0, ordered_at: 1.day.ago)
        order.update!(
          revenue_amount: 50.0,
          settlement_amount: 30.0,
          fee_and_tax_amount: 15.0,
          platform_commission_amount: 10.0,
          item_fee_amount: 3.0,
          service_fee_amount: 2.0,
          shipping_cost_amount: 0,
          financial_synced_at: Time.current
        )

        reconciliation = tiktok_summary[:financial][:tiktok_financial_breakdown][:reconciliation]

        # explicado = 50 (receita) - 15 (taxas) - 0 (frete) = 35; ajuste = 30 (liquidado real) - 35 = -5
        expect(reconciliation.find { |row| row[:key] == "other_adjustments" }[:amount]).to eq(-5.0)
        expect(reconciliation.find { |row| row[:key] == "settlement_amount" }[:amount]).to eq(30.0)
        expect(order.reload.margin).to eq(30.0 - order.cost_price.to_f)
      end

      it "breaks fees down by category with percentage of revenue and orders reached, keeping affiliate separate from platform commission" do
        order = make_order(channel_tiktok, gross: 100, margin: 0, ordered_at: 1.day.ago)
        order.update!(
          revenue_amount: 80.0,
          settlement_amount: 60.0,
          fee_and_tax_amount: 20.0,
          platform_commission_amount: 8.0,
          affiliate_commission_amount: 4.0,
          item_fee_amount: 5.0,
          service_fee_amount: 3.0,
          shipping_cost_amount: 0,
          financial_synced_at: Time.current
        )

        fee_composition = tiktok_summary[:financial][:tiktok_financial_breakdown][:fee_composition]
        platform_line = fee_composition.find { |row| row[:key] == "platform_commission" }
        affiliate_line = fee_composition.find { |row| row[:key] == "affiliate_commission" }

        expect(platform_line).to include(amount: 8.0, orders_count: 1, percentage_of_revenue: 10.0)
        expect(affiliate_line).to include(amount: 4.0, orders_count: 1, percentage_of_revenue: 5.0)
        expect(platform_line[:key]).not_to eq(affiliate_line[:key])
      end

      it "reports tiktok financial coverage with a pending count and a processing status" do
        synced = make_order(channel_tiktok, gross: 50, margin: 0, ordered_at: 1.day.ago)
        synced.update!(revenue_amount: 45, settlement_amount: 40, financial_synced_at: Time.current)
        make_order(channel_tiktok, gross: 30, margin: 0, ordered_at: 1.day.ago)

        coverage = tiktok_summary[:financial][:tiktok_coverage]

        expect(coverage).to include(
          orders_count: 2,
          synced_orders_count: 1,
          pending_orders_count: 1,
          coverage_percentage: 50.0,
          status: "Dados históricos ainda em processamento."
        )
      end

      it "returns a per-day series with revenue, settlement and real profit for synced orders only" do
        synced = make_order(channel_tiktok, gross: 50, margin: 0, ordered_at: 1.day.ago)
        synced.update!(revenue_amount: 45, settlement_amount: 40, cost_price: 10, financial_synced_at: Time.current)
        make_order(channel_tiktok, gross: 30, margin: 0, ordered_at: 1.day.ago) # não sincronizado, não entra na série

        series = tiktok_summary[:financial][:tiktok_daily_series]

        expect(series.size).to eq(1)
        expect(series.first).to include(revenue_amount: 45.0, settlement_amount: 40.0, profit: 30.0, orders_count: 1)
      end

      it "consolidates yampi and tiktok totals without mixing their profit formulas" do
        yampi_product = tenant.products.create!(sku: "SKU-Y", name: "Produto Yampi", cost_price: 20)
        yampi_order = make_order(channel_a, gross: 100, margin: 0, ordered_at: 1.day.ago)
        yampi_order.update!(discount: 10)
        yampi_order.order_items.create!(product: yampi_product, sku: yampi_product.sku, name: yampi_product.name, quantity: 1, unit_price: 100, unit_cost: 20)

        tiktok_product = tenant.products.create!(sku: "SKU-TK2", name: "Produto TikTok", cost_price: 5)
        tiktok_order = make_order(channel_tiktok, gross: 50, margin: 0, ordered_at: 1.day.ago)
        tiktok_order.update!(revenue_amount: 45, settlement_amount: 40, cost_price: 5, financial_synced_at: Time.current)
        tiktok_order.order_items.create!(product: tiktok_product, sku: tiktok_product.sku, name: tiktok_product.name, quantity: 1, unit_price: 45, unit_cost: 5)

        result = described_class.call(
          tenant: tenant,
          params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601)
        )
        consolidated = result[:financial][:consolidated]

        # Yampi: net = 100 - 10 = 90; lucro (fórmula geral) = 90 - 20 (custo) = 70 (sem frete/comissão/imposto/gateway configurados)
        # TikTok: receita efetiva 45; lucro real = 40 (liquidado) - 5 (custo) = 35
        expect(consolidated[:effective_revenue]).to eq(135.0)
        expect(consolidated[:yampi][:real_profit]).to eq(70.0)
        expect(consolidated[:tiktok][:real_profit]).to eq(35.0)
        expect(consolidated[:real_profit]).to eq(105.0)
        expect(consolidated[:orders_count]).to eq(2)
      end
    end

    describe "Visão Geral — receita efetiva com TikTok pendente (backfill em andamento)" do
      let(:channel_tiktok) { tenant.channels.create!(name: "TikTok Shop", platform: "tiktok") }

      def overview_summary(channel_ids: nil)
        params = { from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601 }
        params[:channel_ids] = channel_ids if channel_ids
        described_class.call(tenant: tenant, params: ActionController::Parameters.new(params))
      end

      it "uses revenue_amount for a synced TikTok order, not gross_value - discount" do
        make_order(channel_tiktok, gross: 100, margin: 0, ordered_at: 1.day.ago).update!(
          discount: 30, revenue_amount: 85, financial_synced_at: Time.current
        )

        result = overview_summary(channel_ids: [ channel_tiktok.id.to_s ])

        expect(result[:kpis][:net_revenue]).to eq(85.0)
      end

      it "excludes a pending TikTok order from revenue but keeps it in the operational order count" do
        make_order(channel_tiktok, gross: 100, margin: 0, ordered_at: 1.day.ago) # sem financial_synced_at
        synced = make_order(channel_tiktok, gross: 50, margin: 0, ordered_at: 1.day.ago)
        synced.update!(revenue_amount: 45, financial_synced_at: Time.current)

        result = overview_summary(channel_ids: [ channel_tiktok.id.to_s ])

        expect(result[:kpis][:orders_count]).to eq(2)
        expect(result[:kpis][:net_revenue]).to eq(45.0)
        expect(result[:kpis][:financial_orders_count]).to eq(1)
        expect(result[:kpis][:tiktok_pending_orders_count]).to eq(1)
      end

      it "keeps the legacy gross - discount - refund formula for non-TikTok channels" do
        make_order(channel_a, gross: 200, margin: 0, ordered_at: 1.day.ago, refund: 10).update!(discount: 20)

        result = overview_summary

        expect(result[:kpis][:net_revenue]).to eq(170.0)
      end

      it "computes financial average ticket only over orders with revenue available, not the full TikTok order count" do
        make_order(channel_tiktok, gross: 100, margin: 0, ordered_at: 1.day.ago) # pendente
        synced = make_order(channel_tiktok, gross: 50, margin: 0, ordered_at: 1.day.ago)
        synced.update!(revenue_amount: 40, financial_synced_at: Time.current)

        result = overview_summary(channel_ids: [ channel_tiktok.id.to_s ])

        expect(result[:kpis][:average_ticket]).to eq(40.0)
        expect(result[:kpis][:average_ticket_available]).to eq(true)
      end

      it "returns average_ticket as nil, not a false zero, when no order has revenue available" do
        make_order(channel_tiktok, gross: 100, margin: 0, ordered_at: 1.day.ago) # só pendente

        result = overview_summary(channel_ids: [ channel_tiktok.id.to_s ])

        expect(result[:kpis][:average_ticket]).to be_nil
        expect(result[:kpis][:average_ticket_available]).to eq(false)
        expect(result[:kpis][:net_revenue]).to eq(0.0)
      end

      it "separates total orders from financial orders in the daily timeline" do
        make_order(channel_tiktok, gross: 100, margin: 0, ordered_at: 1.day.ago) # pendente
        synced = make_order(channel_tiktok, gross: 50, margin: 0, ordered_at: 1.day.ago)
        synced.update!(revenue_amount: 45, financial_synced_at: Time.current)

        result = overview_summary(channel_ids: [ channel_tiktok.id.to_s ])
        day = result[:revenue_timeline].first

        expect(day[:orders_count]).to eq(2)
        expect(day[:financial_orders_count]).to eq(1)
        expect(day[:tiktok_pending_orders_count]).to eq(1)
        expect(day[:net]).to eq(45.0)
      end

      it "uses real TikTok revenue in sales by channel and flags coverage" do
        make_order(channel_tiktok, gross: 100, margin: 0, ordered_at: 1.day.ago) # pendente
        synced = make_order(channel_tiktok, gross: 50, margin: 0, ordered_at: 1.day.ago)
        synced.update!(revenue_amount: 45, financial_synced_at: Time.current)
        make_order(channel_a, gross: 30, margin: 0, ordered_at: 1.day.ago)

        result = overview_summary
        tiktok_row = result[:sales_by_channel].find { |row| row[:channel] == "TikTok Shop" }

        expect(tiktok_row[:net_revenue]).to eq(45.0)
        expect(tiktok_row[:orders_count]).to eq(2)
        expect(tiktok_row[:tiktok_coverage_percentage]).to eq(50.0)
      end

      it "keeps operational order count per state but excludes pending TikTok revenue from the state total" do
        make_order(channel_tiktok, gross: 100, margin: 0, ordered_at: 1.day.ago).update!(state: "SP") # pendente
        synced = make_order(channel_tiktok, gross: 50, margin: 0, ordered_at: 1.day.ago)
        synced.update!(state: "SP", revenue_amount: 45, financial_synced_at: Time.current)

        result = overview_summary(channel_ids: [ channel_tiktok.id.to_s ])
        sp = result[:regional_sales][:states].find { |row| row[:state] == "SP" }

        expect(sp[:orders_count]).to eq(2)
        expect(sp[:net_revenue]).to eq(45.0)
        expect(sp[:tiktok_pending_orders_count]).to eq(1)
        expect(sp[:financial_coverage_partial]).to eq(true)
      end

      it "separates seller-funded discount from platform-funded incentive in the main discount total" do
        make_order(channel_tiktok, gross: 50, margin: 0, ordered_at: 1.day.ago).update!(
          discount: 10, seller_discount: 6, platform_discount: 4, revenue_amount: 40, financial_synced_at: Time.current
        )

        result = overview_summary(channel_ids: [ channel_tiktok.id.to_s ])

        expect(result[:coupons][:display_discount_total]).to eq(6.0)
        expect(result[:coupons][:platform_incentive_total]).to eq(4.0)
      end

      it "flags the revenue delta as partial, with a coverage note, when either period has pending TikTok orders" do
        make_order(channel_tiktok, gross: 50, margin: 0, ordered_at: 1.day.ago) # pendente
        synced = make_order(channel_tiktok, gross: 50, margin: 0, ordered_at: 1.day.ago)
        synced.update!(revenue_amount: 45, financial_synced_at: Time.current)

        result = overview_summary(channel_ids: [ channel_tiktok.id.to_s ])

        expect(result[:kpis][:net_revenue_delta_partial]).to eq(true)
        expect(result[:kpis][:net_revenue_delta_note]).to include("Comparação parcial")
      end

      it "exposes current and previous period TikTok coverage" do
        make_order(channel_tiktok, gross: 50, margin: 0, ordered_at: 1.day.ago) # pendente (atual)
        synced_prev = make_order(channel_tiktok, gross: 50, margin: 0, ordered_at: 32.days.ago)
        synced_prev.update!(revenue_amount: 45, financial_synced_at: Time.current)

        result = described_class.call(
          tenant: tenant,
          params: ActionController::Parameters.new(
            from: 29.days.ago.to_date.iso8601, to: Date.current.iso8601, channel_ids: [ channel_tiktok.id.to_s ]
          )
        )

        coverage = result[:overview_financial_coverage]
        expect(coverage[:current_period_partial]).to eq(true)
        expect(coverage[:tiktok_orders_count]).to eq(1)
      end

      it "does not flag a partial-coverage warning when the filter excludes TikTok entirely" do
        make_order(channel_a, gross: 100, margin: 0, ordered_at: 1.day.ago)

        result = overview_summary(channel_ids: [ channel_a.id.to_s ])

        expect(result[:overview_financial_coverage][:current_period_partial]).to eq(false)
        expect(result[:overview_financial_coverage][:tiktok_orders_count]).to eq(0)
      end

      it "shows coverage when the filter is TikTok-only" do
        make_order(channel_tiktok, gross: 50, margin: 0, ordered_at: 1.day.ago) # pendente
        synced = make_order(channel_tiktok, gross: 50, margin: 0, ordered_at: 1.day.ago)
        synced.update!(revenue_amount: 45, financial_synced_at: Time.current)

        result = overview_summary(channel_ids: [ channel_tiktok.id.to_s ])

        expect(result[:overview_financial_coverage][:tiktok_coverage_percentage]).to eq(50.0)
      end
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
