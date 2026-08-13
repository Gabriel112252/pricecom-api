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

    it "computes average ticket per day, per channel" do
      make_order(channel_a, gross: 300, margin: 0, ordered_at: 3.days.ago) # 3rd order on channel_a's day, own bucket
      make_order(channel_b, gross: 500, margin: 0, ordered_at: 1.day.ago)
      make_order(channel_b, gross: 300, margin: 0, ordered_at: 1.day.ago) # same day+channel as the one above -> averaged together

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

      series = result[:orders][:aov_by_channel_series]
      today = 1.day.ago.to_date.iso8601
      three_days_ago = 3.days.ago.to_date.iso8601

      # channel_a's original 2 orders (100 and 200-20refund=180 net) live on "1 day ago" per the outer `before` block
      channel_a_today = series.find { |row| row[:channel] == "Yampi" && row[:date] == today }
      channel_a_3days = series.find { |row| row[:channel] == "Yampi" && row[:date] == three_days_ago }
      channel_b_today = series.find { |row| row[:channel] == "Shopify" && row[:date] == today }

      expect(channel_a_today[:aov]).to eq(140.0) # (100 + 180) / 2, same as the aggregate aov_by_channel above
      expect(channel_a_3days[:aov]).to eq(300.0)
      expect(channel_b_today[:aov]).to eq(400.0) # (500 + 300) / 2
    end
  end

  describe "Vendas — mesma fórmula de receita entre canais (sem divergência silenciosa)" do
    let(:channel_tiktok) { tenant.channels.create!(name: "TikTok Shop", platform: "tiktok") }

    it "uses the same confirmed-or-estimated TikTok formula in by_channel, by_channel_series and aov_by_channel" do
      make_order(channel_tiktok, gross: 100, margin: 0, ordered_at: 1.day.ago).update!(seller_discount: 10) # pendente, estimado 90

      result = described_class.call(
        tenant: tenant,
        params: ActionController::Parameters.new(
          from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601, channel_ids: [ channel_tiktok.id.to_s ]
        )
      )

      expect(result[:revenue][:by_channel]["TikTok Shop"]).to eq(90.0)
      expect(result[:revenue][:by_channel_series].sum { |row| row[:gross] }).to eq(90.0)
      expect(result[:orders][:aov_by_channel]["TikTok Shop"]).to eq(90.0)
    end

    it "uses the confirmed revenue_amount, not the estimate, once the order is synced" do
      synced = make_order(channel_tiktok, gross: 100, margin: 0, ordered_at: 1.day.ago)
      synced.update!(seller_discount: 10, revenue_amount: 82, financial_synced_at: Time.current)

      result = described_class.call(
        tenant: tenant,
        params: ActionController::Parameters.new(
          from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601, channel_ids: [ channel_tiktok.id.to_s ]
        )
      )

      expect(result[:revenue][:by_channel]["TikTok Shop"]).to eq(82.0)
      expect(result[:orders][:aov_by_channel]["TikTok Shop"]).to eq(82.0)
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

    # Regressão: TiktokOrderNormalizer/YampiOrderNormalizer/ShopifyOrderNormalizer
    # marcam order_type: "cancellation" (não "sale") assim que o status vira
    # cancelado, e Integrations::Orders::UpsertOrder regrava order_type a cada
    # sync — então em produção um pedido cancelado sempre chega com esse
    # order_type, nunca "sale"/"refund" como os testes acima simulam via
    # make_order. O card ficava sempre zerado para os três canais por causa
    # disso; ver canceled_amount_for.
    it "counts canceled orders even when order_type is 'cancellation', matching what the channel normalizers persist in production" do
      make_order(channel_a, gross: 80, margin: 0, ordered_at: 1.day.ago).update!(status: "cancelled", order_type: "cancellation")
      make_order(channel_b, gross: 20, margin: 0, ordered_at: 1.day.ago).update!(status: "cancelado", order_type: "cancellation")

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

      expect(result[:revenue_breakdown][:cancellations_and_refunds]).to eq(100.0)
      expect(result[:revenue_breakdown][:gross_revenue]).to eq(100.0)
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

      # Regressão: affiliate_ads_commission_amount e
      # affiliate_partner_commission_amount eram somadas em other_fees_total
      # (via fórmula residual, sem serem subtraídas) — perdendo a
      # distinção. fee_and_tax_amount inclui 2.0 extra genuinamente não
      # atribuído a nenhuma categoria nomeada, pra provar que a fórmula
      # nova (que agora SUBTRAI os dois novos campos) chega no residual
      # correto (2.0), não no antigo (5.0, que incluía affiliate_ads +
      # affiliate_partner por engano).
      it "reports affiliate_ads/affiliate_partner commission separately and excludes them from other_fees_total" do
        make_order(channel_tiktok, gross: 100, margin: 0, ordered_at: 1.day.ago).update!(
          revenue_amount: 100.0,
          settlement_amount: 75.0,
          fee_and_tax_amount: 25.0,
          platform_commission_amount: 8.0,
          affiliate_commission_amount: 4.0,
          affiliate_ads_commission_amount: 2.0,
          affiliate_partner_commission_amount: 1.0,
          item_fee_amount: 5.0,
          service_fee_amount: 3.0,
          shipping_cost_amount: 0,
          financial_synced_at: Time.current
        )

        financial = tiktok_summary[:financial][:tiktok_financial_breakdown]

        expect(financial).to include(
          affiliate_commission_total: 4.0,
          affiliate_ads_commission_total: 2.0,
          affiliate_partner_commission_total: 1.0,
          other_fees_total: 2.0
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

      it "estimates a pending order's contribution to buyer paid product total, ignoring any stale revenue_amount left on it" do
        make_order(channel_tiktok, gross: 36.46, margin: 0, ordered_at: 1.day.ago).update!(
          discount: 18.52,
          seller_discount: 0,
          platform_discount: 0,
          revenue_amount: 29.90,
          settlement_amount: 17.83,
          fee_and_tax_amount: 12.07,
          financial_synced_at: Time.current
        )
        # financial_synced_at: nil e revenue_amount: 80 propositalmente
        # divergente do que a estimativa (gross - seller_discount = 100 - 0)
        # daria — prova que o valor confirmado obsoleto não vaza mesmo
        # quando a coluna já tem algo gravado.
        make_order(channel_tiktok, gross: 100, margin: 0, ordered_at: 1.day.ago).update!(
          discount: 20,
          platform_discount: 20,
          revenue_amount: 80,
          financial_synced_at: nil
        )

        discount = tiktok_summary[:coupons][:discount_breakdown_tiktok]

        # order1 confirmado (29.90) + order2 estimado (100 - seller_discount 0) = 129.90
        # platform_subsidy: order1 11.96 (fallback) + order2 20 (coluna direta) = 31.96
        expect(discount[:buyer_paid_product_total]).to eq(97.94) # 129.90 - 31.96
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

      it "blends confirmed and estimated revenue in revenue_amount_total without letting the estimate leak into real_margin_pct" do
        synced = make_order(channel_tiktok, gross: 36.46, margin: 0, ordered_at: 1.day.ago)
        synced.update!(revenue_amount: 29.90, settlement_amount: 17.83, fee_and_tax_amount: 12.07, cost_price: 5.83, financial_synced_at: Time.current)
        product = tenant.products.create!(sku: "SKU-TK", name: "Produto TikTok", cost_price: 5.83)
        synced.order_items.create!(product: product, sku: product.sku, name: product.name, quantity: 1, unit_price: 29.90, unit_cost: 5.83)
        pending = make_order(channel_tiktok, gross: 50, margin: 0, ordered_at: 1.day.ago) # pendente, estimado 42
        pending.update!(seller_discount: 8)
        # order_items com custo conhecido, senão data_quality marca o pedido
        # como "sem custo completo" e financial_available cai pra false —
        # eixo de qualidade diferente do que este teste quer exercitar.
        pending.order_items.create!(product: product, sku: product.sku, name: product.name, quantity: 1, unit_price: 42, unit_cost: 5)

        financial = tiktok_summary[:financial][:tiktok_financial_breakdown]

        # revenue_amount_total é o Grupo B (confirmado + estimado): 29.90 + 42.
        expect(financial[:revenue_amount_total]).to eq(71.90)
        expect(financial[:pending_orders_count]).to eq(1)
        expect(financial[:pending_estimated_revenue]).to eq(42.0)
        # real_margin_pct é Grupo C — continua só sobre o confirmado (29.90),
        # nunca dividido pelo blended (71.90), senão a margem cairia à toa.
        expect(financial[:real_margin_pct]).to eq(40.13)
      end

      it "returns settlement/fees/real profit as nil, not a misleading zero, when no order in the period has synced yet" do
        make_order(channel_tiktok, gross: 50, margin: 0, ordered_at: 1.day.ago).update!(seller_discount: 5) # só pendente

        financial = tiktok_summary[:financial][:tiktok_financial_breakdown]

        expect(financial[:settlement_amount_total]).to be_nil
        expect(financial[:fee_and_tax_amount_total]).to be_nil
        expect(financial[:real_profit_total]).to be_nil
        expect(financial[:real_margin_pct]).to be_nil
        expect(financial[:real_profit_available]).to eq(false)
        # revenue_amount_total continua a estimativa (Grupo B), não nil.
        expect(financial[:revenue_amount_total]).to eq(45.0)
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

      it "breaks affiliate commission into three separate composition and reconciliation lines" do
        order = make_order(channel_tiktok, gross: 100, margin: 0, ordered_at: 1.day.ago)
        order.update!(
          revenue_amount: 100.0,
          settlement_amount: 75.0,
          fee_and_tax_amount: 25.0,
          platform_commission_amount: 8.0,
          affiliate_commission_amount: 4.0,
          affiliate_ads_commission_amount: 2.0,
          affiliate_partner_commission_amount: 1.0,
          item_fee_amount: 5.0,
          service_fee_amount: 3.0,
          shipping_cost_amount: 0,
          financial_synced_at: Time.current
        )

        breakdown = tiktok_summary[:financial][:tiktok_financial_breakdown]
        fee_composition = breakdown[:fee_composition]
        reconciliation = breakdown[:reconciliation]

        organic = fee_composition.find { |row| row[:key] == "affiliate_commission" }
        ads = fee_composition.find { |row| row[:key] == "affiliate_ads_commission" }
        partner = fee_composition.find { |row| row[:key] == "affiliate_partner_commission" }

        expect(organic).to include(label: "Comissão de afiliados (orgânico)", amount: 4.0, orders_count: 1)
        expect(ads).to include(label: "Comissão de afiliados (via anúncio)", amount: 2.0, orders_count: 1)
        expect(partner).to include(label: "Comissão de parceiros de afiliados", amount: 1.0, orders_count: 1)

        expect(reconciliation.find { |row| row[:key] == "affiliate_ads_commission" }).to include(amount: -2.0)
        expect(reconciliation.find { |row| row[:key] == "affiliate_partner_commission" }).to include(amount: -1.0)
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

      it "estimates a pending TikTok order's revenue from gross_value - seller_discount instead of excluding it" do
        make_order(channel_tiktok, gross: 100, margin: 0, ordered_at: 1.day.ago).update!(seller_discount: 12) # pendente
        synced = make_order(channel_tiktok, gross: 50, margin: 0, ordered_at: 1.day.ago)
        synced.update!(revenue_amount: 45, financial_synced_at: Time.current)

        result = overview_summary(channel_ids: [ channel_tiktok.id.to_s ])

        expect(result[:kpis][:orders_count]).to eq(2)
        expect(result[:kpis][:net_revenue]).to eq(133.0) # 45 confirmado + (100 - 12) estimado
        expect(result[:kpis][:financial_orders_count]).to eq(1)
        expect(result[:kpis][:tiktok_pending_orders_count]).to eq(1)
      end

      it "keeps the legacy gross - discount - refund formula for non-TikTok channels" do
        make_order(channel_a, gross: 200, margin: 0, ordered_at: 1.day.ago, refund: 10).update!(discount: 20)

        result = overview_summary

        expect(result[:kpis][:net_revenue]).to eq(170.0)
      end

      it "computes average ticket over ALL tiktok orders, blending confirmed and estimated revenue" do
        make_order(channel_tiktok, gross: 100, margin: 0, ordered_at: 1.day.ago).update!(seller_discount: 20) # pendente, estimado 80
        synced = make_order(channel_tiktok, gross: 50, margin: 0, ordered_at: 1.day.ago)
        synced.update!(revenue_amount: 40, financial_synced_at: Time.current)

        result = overview_summary(channel_ids: [ channel_tiktok.id.to_s ])

        expect(result[:kpis][:average_ticket]).to eq(60.0) # (80 estimado + 40 confirmado) / 2
        expect(result[:kpis][:average_ticket_available]).to eq(true)
      end

      it "returns average_ticket as nil and net_revenue as zero when there are no orders at all in the period" do
        result = overview_summary(channel_ids: [ channel_tiktok.id.to_s ])

        expect(result[:kpis][:average_ticket]).to be_nil
        expect(result[:kpis][:average_ticket_available]).to eq(false)
        expect(result[:kpis][:net_revenue]).to eq(0.0)
      end

      it "separates total orders from financial orders in the daily timeline, with net revenue including the pending order's estimate" do
        make_order(channel_tiktok, gross: 100, margin: 0, ordered_at: 1.day.ago).update!(seller_discount: 10) # pendente, estimado 90
        synced = make_order(channel_tiktok, gross: 50, margin: 0, ordered_at: 1.day.ago)
        synced.update!(revenue_amount: 45, financial_synced_at: Time.current)

        result = overview_summary(channel_ids: [ channel_tiktok.id.to_s ])
        day = result[:revenue_timeline].first

        expect(day[:orders_count]).to eq(2)
        expect(day[:financial_orders_count]).to eq(1)
        expect(day[:tiktok_pending_orders_count]).to eq(1)
        expect(day[:net]).to eq(135.0) # 45 confirmado + 90 estimado
        expect(day[:average_ticket]).to eq(67.5) # 135 / 2 pedidos
      end

      it "blends confirmed and estimated TikTok revenue in sales by channel and flags coverage" do
        make_order(channel_tiktok, gross: 100, margin: 0, ordered_at: 1.day.ago).update!(seller_discount: 10) # pendente, estimado 90
        synced = make_order(channel_tiktok, gross: 50, margin: 0, ordered_at: 1.day.ago)
        synced.update!(revenue_amount: 45, financial_synced_at: Time.current)
        make_order(channel_a, gross: 30, margin: 0, ordered_at: 1.day.ago)

        result = overview_summary
        tiktok_row = result[:sales_by_channel].find { |row| row[:channel] == "TikTok Shop" }

        expect(tiktok_row[:net_revenue]).to eq(135.0)
        expect(tiktok_row[:orders_count]).to eq(2)
        expect(tiktok_row[:tiktok_coverage_percentage]).to eq(50.0)
      end

      it "keeps operational order count per state and includes an estimated value for the pending TikTok order, flagged as partial coverage" do
        make_order(channel_tiktok, gross: 100, margin: 0, ordered_at: 1.day.ago).update!(state: "SP", seller_discount: 10) # pendente, estimado 90
        synced = make_order(channel_tiktok, gross: 50, margin: 0, ordered_at: 1.day.ago)
        synced.update!(state: "SP", revenue_amount: 45, financial_synced_at: Time.current)

        result = overview_summary(channel_ids: [ channel_tiktok.id.to_s ])
        sp = result[:regional_sales][:states].find { |row| row[:state] == "SP" }

        expect(sp[:orders_count]).to eq(2)
        expect(sp[:net_revenue]).to eq(135.0)
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
        expect(result[:kpis][:net_revenue_delta_note]).to include("Inclui estimativa")
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

  # Regressão: build_top_products_by_revenue/margin e
  # build_product_turnover_summary montavam a query direto em OrderItem
  # filtrando só tenant+período, nunca channel_ids — a aba Produtos do
  # dashboard ignorava o filtro de canal enquanto o resto do resumo (KPIs,
  # gráficos) já respeitava. Corrigido trocando a base da query pra
  # `orders_in_period(period)`, que já aplica channel_ids do mesmo jeito
  # que todo o resto do summary.
  describe "top products / turnover — respeitam o filtro de canal" do
    let(:product) { tenant.products.create!(sku: "SKU-CANAL", name: "Produto Canal", cost_price: 10) }

    def add_item(order, qty:, unit_price:, unit_cost: 10)
      order.order_items.create!(
        product: product, sku: product.sku, name: product.name,
        quantity: qty, unit_price: unit_price, unit_cost: unit_cost
      )
    end

    before do
      # unit_cost diferente por canal de propósito — se a query somasse os
      # dois canais junto (o bug), a margem "só de A" apareceria diluída
      # pelo custo de B, e o teste pegaria isso; com unit_cost igual nos
      # dois, o percentual dá 90% em qualquer combinação e o teste não
      # provaria nada.
      add_item(make_order(channel_a, gross: 200, margin: 100, ordered_at: 1.day.ago), qty: 2, unit_price: 100, unit_cost: 10)
      add_item(make_order(channel_b, gross: 300, margin: 150, ordered_at: 1.day.ago), qty: 3, unit_price: 100, unit_cost: 50)
    end

    def call_for(channel_ids: nil)
      params = { from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601 }
      params[:channel_ids] = channel_ids if channel_ids
      described_class.call(tenant: tenant, params: ActionController::Parameters.new(params))
    end

    it "top_products_by_revenue: só a receita do canal filtrado, soma dos dois quando todos os canais" do
      only_a = call_for(channel_ids: [ channel_a.id.to_s ])
      only_b = call_for(channel_ids: [ channel_b.id.to_s ])
      all = call_for

      expect(only_a[:top_products_by_revenue]).to eq([ { sku: product.sku, name: product.name, revenue: 200.0 } ])
      expect(only_b[:top_products_by_revenue]).to eq([ { sku: product.sku, name: product.name, revenue: 300.0 } ])
      expect(all[:top_products_by_revenue]).to eq([ { sku: product.sku, name: product.name, revenue: 500.0 } ])
    end

    it "top_products_by_margin: mesmo recorte por canal (unit_cost difere entre canais de propósito)" do
      only_a = call_for(channel_ids: [ channel_a.id.to_s ])
      only_b = call_for(channel_ids: [ channel_b.id.to_s ])
      all = call_for

      expect(only_a[:top_products_by_margin]).to eq([ { sku: product.sku, name: product.name, margin_pct: 90.0 } ])
      expect(only_b[:top_products_by_margin]).to eq([ { sku: product.sku, name: product.name, margin_pct: 50.0 } ])
      # combinado: receita 500, custo (2*10 + 3*50)=170 -> margem 66%
      expect(all[:top_products_by_margin]).to eq([ { sku: product.sku, name: product.name, margin_pct: 66.0 } ])
    end

    it "product_turnover_summary: quantidade só do canal filtrado, soma quando todos os canais" do
      only_a = call_for(channel_ids: [ channel_a.id.to_s ])
      only_b = call_for(channel_ids: [ channel_b.id.to_s ])
      all = call_for

      expect(only_a[:product_turnover_summary].first).to include(sku: product.sku, total_qty: 2.0)
      expect(only_b[:product_turnover_summary].first).to include(sku: product.sku, total_qty: 3.0)
      expect(all[:product_turnover_summary].first).to include(sku: product.sku, total_qty: 5.0)
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

  describe "TikTok item-level discount (seller vs platform, no double count)" do
    let(:tiktok_channel) { tenant.channels.create!(name: "TikTok Shop", platform: "tiktok") }
    let(:product) { tenant.products.create!(sku: "CAMISA-P", name: "Camisa Básica P", cost_price: 17.23) }

    # Mesmo pedido de exemplo da correção de 21/07/2026: item original_price
    # 59.45 x2, seller_discount 21.02 x2, platform_discount 3.39 x2 =>
    # unit_price (já líquido dos DOIS descontos) 35.04 x2 = 70.08.
    def make_tiktok_item(order)
      order.order_items.create!(
        product: product, sku: "CAMISA-P", name: "Camisa Básica P", quantity: 2,
        unit_price: 35.04, unit_cost: 17.23,
        discount: 48.82, seller_discount: 42.04, platform_discount: 6.78
      )
    end

    # Simula uma linha de order_items de fato antiga (criada antes do fix,
    # nunca ressincronizada — created_at é gerenciado pelo Rails no create!,
    # então update_column é necessário pra forçar a data sem passar pelos
    # callbacks normais).
    def make_old_unreprocessed_item(order, unit_price:)
      item = order.order_items.create!(
        product: product, sku: "CAMISA-P", name: "Camisa Básica P", quantity: 1,
        unit_price: unit_price, unit_cost: 17.23,
        discount: 0, seller_discount: 0, platform_discount: 0
      )
      item.update_column(:created_at, described_class::TIKTOK_ITEM_DISCOUNT_SPLIT_FIX_DEPLOYED_AT - 1.day)
      item
    end

    it "does not double-count platform_discount in top_products_by_revenue " \
       "(unit_price is already net of both discounts; correct revenue adds platform_discount back)" do
      order = make_order(tiktok_channel, gross: 118.90, margin: 0, ordered_at: 1.day.ago)
      make_tiktok_item(order)

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

      # 70.08 (qty*unit_price) + 6.78 (platform_discount) = 76.86, matching
      # TikTok's own "Vendas líquidas dos produtos" (118.90 - seller 42.04).
      # The old formula (qty*unit_price - discount) yielded 21.26.
      expect(result[:top_products_by_revenue].first).to include(sku: "CAMISA-P", revenue: 76.86)
    end

    it "computes top_products_by_margin against the correct (seller-discount-only) revenue" do
      order = make_order(tiktok_channel, gross: 118.90, margin: 0, ordered_at: 1.day.ago)
      make_tiktok_item(order)

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

      # revenue 76.86, cost 2*17.23=34.46 => (76.86-34.46)/76.86*100 = 55.17%
      expect(result[:top_products_by_margin].first).to include(sku: "CAMISA-P", margin_pct: 55.17)
    end

    it "shows only seller_discount (not seller+platform) as the item discount in coupons.by_product" do
      order = make_order(tiktok_channel, gross: 118.90, margin: 0, ordered_at: 1.day.ago)
      make_tiktok_item(order)

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

      row = result[:coupons][:by_product].first
      # discount_total 42.04 (seller only, not 48.82 combined); list price
      # reconstructed as 70.08 + 42.04 + 6.78 = 118.90 => 42.04/118.90 = 35.36%.
      expect(row).to include(sku: "CAMISA-P", discount_total: 42.04, discount_pct: 35.36)
    end

    # Regressão: o backfill histórico (Integrations::Tiktok::
    # DiscountBackfillService) parou em 42.750/154.195 pedidos por rate
    # limit — os restantes têm order_items.seller_discount/
    # platform_discount ainda em 0 (valor padrão pós-migration, idêntico ao
    # de um item nunca ressincronizado). Misturar esses itens "antigos" com
    # os já corrigidos no mesmo SUM produzia receita/margem/desconto
    # inconsistentes pro mesmo SKU. item_discount_split_reliable_sql
    # resolve isso via order_items.created_at (a linha é sempre destruída e
    # recriada a cada re-sync — UpsertOrder#upsert_items), não pela
    # presença de valor > 0 nos campos (que teria falso negativo pra item
    # legitimamente sem desconto processado pelo normalizer já correto).
    describe "reliability of the split (pre- vs post-fix orders)" do
      it "excludes a pre-fix TikTok item (zeroed split, never resynced) from top_products_by_revenue/margin, instead of diluting the reprocessed one" do
        reprocessed_order = make_order(tiktok_channel, gross: 118.90, margin: 0, ordered_at: 1.day.ago)
        make_tiktok_item(reprocessed_order)

        old_order = make_order(tiktok_channel, gross: 100.0, margin: 0, ordered_at: 1.day.ago)
        make_old_unreprocessed_item(old_order, unit_price: 100.0)

        result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

        # Só a linha reprocessada entra: 76.86, igual ao teste isolado acima.
        # Se o item antigo entrasse, a soma ficaria 176.86 (ou pior, some
        # revenue subtraindo um discount fantasma de 0).
        expect(result[:top_products_by_revenue].first).to include(sku: "CAMISA-P", revenue: 76.86)
        expect(result[:top_products_by_margin].first).to include(sku: "CAMISA-P", margin_pct: 55.17)
      end

      it "excludes a pre-fix TikTok item from coupons.by_product too" do
        old_order = make_order(tiktok_channel, gross: 100.0, margin: 0, ordered_at: 1.day.ago)
        make_old_unreprocessed_item(old_order, unit_price: 100.0)

        result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

        expect(result[:coupons][:by_product]).to eq([])
      end

      it "does not exclude a post-fix TikTok item with a genuinely zero discount (no false negative)" do
        order = make_order(tiktok_channel, gross: 100.0, margin: 0, ordered_at: 1.day.ago)
        order.order_items.create!(
          product: product, sku: "CAMISA-P", name: "Camisa Básica P", quantity: 1,
          unit_price: 100.0, unit_cost: 17.23, discount: 0, seller_discount: 0, platform_discount: 0
        )

        result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

        expect(result[:top_products_by_revenue].first).to include(sku: "CAMISA-P", revenue: 100.0)
      end

      it "never excludes a non-TikTok item, regardless of created_at (the bug never applied to other channels)" do
        caneca = tenant.products.create!(sku: "CANECA", name: "Caneca", cost_price: 30.0)
        old_yampi_item = make_order(channel_a, gross: 100.0, margin: 0, ordered_at: 1.day.ago)
          .order_items.create!(product: caneca, sku: "CANECA", name: "Caneca", quantity: 1, unit_price: 100.0, unit_cost: 30.0, discount: 0)
        old_yampi_item.update_column(:created_at, described_class::TIKTOK_ITEM_DISCOUNT_SPLIT_FIX_DEPLOYED_AT - 1.year)

        result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

        expect(result[:top_products_by_revenue].first).to include(sku: "CANECA", revenue: 100.0)
      end
    end

    describe "tiktok_product_data_coverage" do
      it "is unavailable when there is no TikTok order in the period" do
        make_order(channel_a, gross: 100, margin: 0, ordered_at: 1.day.ago)

        result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

        expect(result[:tiktok_product_data_coverage]).to eq(available: false)
      end

      it "reports 100% coverage and partial: false when every item in the period was reprocessed" do
        order = make_order(tiktok_channel, gross: 118.90, margin: 0, ordered_at: 1.day.ago)
        make_tiktok_item(order)

        result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

        expect(result[:tiktok_product_data_coverage]).to eq(
          available: true, coverage_pct: 100.0, partial: false, reliable_count: 1, total_count: 1
        )
      end

      it "reports partial coverage when some TikTok items in the period are still pre-fix" do
        reprocessed_order = make_order(tiktok_channel, gross: 118.90, margin: 0, ordered_at: 1.day.ago)
        make_tiktok_item(reprocessed_order)
        old_order = make_order(tiktok_channel, gross: 100.0, margin: 0, ordered_at: 1.day.ago)
        make_old_unreprocessed_item(old_order, unit_price: 100.0)

        result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

        expect(result[:tiktok_product_data_coverage]).to eq(
          available: true, coverage_pct: 50.0, partial: true, reliable_count: 1, total_count: 2
        )
      end
    end
  end

  describe "returns_and_refunds (aba Financeiro)" do
    def make_item(order, sku:, name: sku, quantity: 1, unit_price: 100, is_gift: false)
      order.order_items.create!(sku: sku, name: name, quantity: quantity, unit_price: unit_price, is_gift: is_gift)
    end

    def make_refund(order, amount:, reason: nil, refunded_at: 1.day.ago, external_id: "ext-#{SecureRandom.hex(4)}")
      tenant.order_refunds.create!(order: order, amount: amount, reason: reason, refunded_at: refunded_at, external_id: external_id)
    end

    it "returns zeroed summary and empty rankings when there are no refunds in the period" do
      make_order(channel_a, gross: 100, margin: 0, ordered_at: 1.day.ago)

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

      returns_and_refunds = result[:financial][:returns_and_refunds]
      expect(returns_and_refunds[:summary]).to eq(total_refunded: 0.0, refunded_pct_of_gross: 0.0)
      expect(returns_and_refunds[:top_returned_products]).to eq([])
      expect(returns_and_refunds[:top_return_reasons]).to eq([])
    end

    it "sums total_refunded and computes its share of the period's gross revenue" do
      order_a = make_order(channel_a, gross: 100, margin: 0, ordered_at: 1.day.ago)
      order_b = make_order(channel_a, gross: 200, margin: 0, ordered_at: 1.day.ago)
      make_refund(order_a, amount: 30)
      make_refund(order_b, amount: 20)

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

      # gross bruto do período = 100 + 200 = 300; reembolsado = 30 + 20 = 50 => 16.67%
      summary = result[:financial][:returns_and_refunds][:summary]
      expect(summary[:total_refunded]).to eq(50.0)
      expect(summary[:refunded_pct_of_gross]).to eq(16.67)
    end

    it "includes canceled orders' gross_value in the denominator, same as the revenue breakdown card" do
      order = make_order(channel_a, gross: 100, margin: 0, ordered_at: 1.day.ago)
      make_order(channel_a, gross: 50, margin: 0, ordered_at: 1.day.ago).update!(status: "cancelado", order_type: "cancellation")
      make_refund(order, amount: 15)

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

      # gross bruto = 100 (venda válida) + 50 (cancelado) = 150; 15/150 = 10%
      expect(result[:financial][:returns_and_refunds][:summary][:refunded_pct_of_gross]).to eq(10.0)
    end

    describe "top_returned_products" do
      it "ranks products by refunds_count desc and splits each refund's amount evenly across the order's non-gift items" do
        order_one_item = make_order(channel_a, gross: 100, margin: 0, ordered_at: 1.day.ago)
        make_item(order_one_item, sku: "CAMISA-P", name: "Camisa P")
        make_refund(order_one_item, amount: 40)

        order_two_items = make_order(channel_a, gross: 200, margin: 0, ordered_at: 1.day.ago)
        make_item(order_two_items, sku: "CAMISA-P", name: "Camisa P")
        make_item(order_two_items, sku: "CALCA-M", name: "Calça M")
        make_refund(order_two_items, amount: 60)

        result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

        products = result[:financial][:returns_and_refunds][:top_returned_products]
        camisa = products.find { |row| row[:sku] == "CAMISA-P" }
        calca = products.find { |row| row[:sku] == "CALCA-M" }

        # CAMISA-P aparece nos dois pedidos devolvidos (refunds_count = 2);
        # valor = 40 (rateio 1/1 no pedido de 1 item) + 30 (rateio 1/2 no
        # pedido de 2 itens) = 70.
        expect(camisa).to include(sku: "CAMISA-P", name: "Camisa P", refunds_count: 2, refund_amount: 70.0)
        # CALCA-M só no pedido de 2 itens: 60 * 1/2 = 30.
        expect(calca).to include(sku: "CALCA-M", name: "Calça M", refunds_count: 1, refund_amount: 30.0)
        expect(products.first[:sku]).to eq("CAMISA-P")
      end

      it "excludes gift items from the split and from the ranking" do
        order = make_order(channel_a, gross: 100, margin: 0, ordered_at: 1.day.ago)
        make_item(order, sku: "CAMISA-P", name: "Camisa P")
        make_item(order, sku: "BRINDE", name: "Brinde", is_gift: true)
        make_refund(order, amount: 50)

        result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

        products = result[:financial][:returns_and_refunds][:top_returned_products]
        expect(products.map { |row| row[:sku] }).to eq([ "CAMISA-P" ])
        expect(products.first[:refund_amount]).to eq(50.0)
      end

      it "ignores refunds from orders outside the requested period" do
        old_order = make_order(channel_a, gross: 100, margin: 0, ordered_at: 40.days.ago)
        make_item(old_order, sku: "CAMISA-P")
        make_refund(old_order, amount: 40)

        result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

        expect(result[:financial][:returns_and_refunds][:top_returned_products]).to eq([])
      end
    end

    describe "top_return_reasons" do
      it "ranks reasons by refunds_count desc, summing the refunded amount per reason" do
        order_a = make_order(channel_a, gross: 100, margin: 0, ordered_at: 1.day.ago)
        order_b = make_order(channel_a, gross: 100, margin: 0, ordered_at: 1.day.ago)
        order_c = make_order(channel_a, gross: 100, margin: 0, ordered_at: 1.day.ago)
        make_refund(order_a, amount: 40, reason: "Package arrived damaged")
        make_refund(order_b, amount: 25, reason: "Package arrived damaged")
        make_refund(order_c, amount: 10, reason: "Received the wrong item")

        result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

        reasons = result[:financial][:returns_and_refunds][:top_return_reasons]
        expect(reasons.first).to include(reason: "Package arrived damaged", refunds_count: 2, refund_amount: 65.0)
        expect(reasons.second).to include(reason: "Received the wrong item", refunds_count: 1, refund_amount: 10.0)
      end

      it "excludes refunds without a reason from the ranking" do
        order = make_order(channel_a, gross: 100, margin: 0, ordered_at: 1.day.ago)
        make_refund(order, amount: 40, reason: nil)

        result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601))

        expect(result[:financial][:returns_and_refunds][:top_return_reasons]).to eq([])
      end
    end
  end

  describe "tiktok_content_format_breakdown" do
    let(:channel_tiktok) { tenant.channels.create!(name: "TikTok Shop", platform: "tiktok") }

    def summary(channel_ids: nil)
      params = { from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601 }
      params[:channel_ids] = channel_ids if channel_ids
      described_class.call(tenant: tenant, params: ActionController::Parameters.new(params))
    end

    def make_snapshot(period_start:, period_end:, synced_at:, gmv_total: 1000, gmv_live: 600, gmv_video: 300, gmv_product_card: 100)
      tenant.shop_analytics_snapshots.create!(
        channel: channel_tiktok, period_start: period_start, period_end: period_end, synced_at: synced_at,
        gmv_total: gmv_total, gmv_live: gmv_live, gmv_video: gmv_video, gmv_product_card: gmv_product_card,
        orders: 42, buyers: 38, product_impressions: 5000, product_page_views: 1200, cancellations_and_returns: 3,
        refunds_amount: 50
      )
    end

    it "is unavailable when there is no snapshot yet" do
      channel_tiktok

      expect(summary[:tiktok_content_format_breakdown]).to eq(available: false)
    end

    it "is unavailable when the tiktok channel is filtered out" do
      make_snapshot(period_start: 30.days.ago.to_date, period_end: Date.current, synced_at: Time.current)

      expect(summary(channel_ids: [ channel_a.id.to_s ])[:tiktok_content_format_breakdown]).to eq(available: false)
    end

    it "shows the GMV breakdown by content format with percentage of the snapshot's own total" do
      make_snapshot(period_start: 30.days.ago.to_date, period_end: Date.current, synced_at: Time.current)

      breakdown = summary[:tiktok_content_format_breakdown]

      expect(breakdown[:available]).to eq(true)
      expect(breakdown[:gmv_total]).to eq(1000.0)
      live = breakdown[:formats].find { |row| row[:key] == "live" }
      video = breakdown[:formats].find { |row| row[:key] == "video" }
      product_card = breakdown[:formats].find { |row| row[:key] == "product_card" }
      expect(live).to include(label: "LIVE", gmv: 600.0, pct: 60.0)
      expect(video).to include(label: "Vídeo", gmv: 300.0, pct: 30.0)
      expect(product_card).to include(label: "Card de produto", gmv: 100.0, pct: 10.0)
    end

    it "exposes the aggregate funnel (impressions -> page views -> orders -> cancellations)" do
      make_snapshot(period_start: 30.days.ago.to_date, period_end: Date.current, synced_at: Time.current)

      funnel = summary[:tiktok_content_format_breakdown][:funnel]

      expect(funnel).to eq(
        product_impressions: 5000, product_page_views: 1200, orders: 42, cancellations_and_returns: 3
      )
    end

    it "uses the most recently synced snapshot, regardless of the dashboard's selected period" do
      make_snapshot(period_start: 60.days.ago.to_date, period_end: 31.days.ago.to_date, synced_at: 2.days.ago, gmv_total: 500)
      make_snapshot(period_start: 30.days.ago.to_date, period_end: Date.current, synced_at: Time.current, gmv_total: 1000)

      breakdown = summary[:tiktok_content_format_breakdown]

      expect(breakdown[:gmv_total]).to eq(1000.0)
      expect(breakdown[:period_end]).to eq(Date.current.iso8601)
    end
  end

  describe "yampi_utm_breakdown" do
    def summary(channel_ids: nil)
      params = { from: 6.days.ago.to_date.iso8601, to: Date.current.iso8601 }
      params[:channel_ids] = channel_ids if channel_ids
      described_class.call(tenant: tenant, params: ActionController::Parameters.new(params))
    end

    def make_yampi_order(gross:, utm_source: nil, utm_medium: nil, utm_campaign: nil)
      tenant.orders.create!(
        channel: channel_a, external_id: "order-#{SecureRandom.hex(4)}", order_number: "N1", order_type: "sale",
        gross_value: gross, ordered_at: 1.day.ago, utm_source: utm_source, utm_medium: utm_medium, utm_campaign: utm_campaign
      )
    end

    it "is unavailable when the yampi channel is filtered out" do
      channel_b # Shopify
      make_yampi_order(gross: 100)

      expect(summary(channel_ids: [ channel_b.id.to_s ])[:yampi_utm_breakdown]).to eq(available: false)
    end

    it "reports zero orders without dividing by zero when there are no yampi orders in the period" do
      channel_a

      expect(summary[:yampi_utm_breakdown]).to eq(available: true, total_orders: 0)
    end

    it "classifies an order with utm_medium present as ads, and absent as organic" do
      make_yampi_order(gross: 100, utm_source: "facebook", utm_medium: "cpc", utm_campaign: "blackfriday")
      make_yampi_order(gross: 50)

      breakdown = summary[:yampi_utm_breakdown]

      expect(breakdown[:total_orders]).to eq(2)
      expect(breakdown[:ads]).to eq(orders_count: 1, revenue: 100.0, orders_pct: 50.0)
      expect(breakdown[:organic]).to eq(orders_count: 1, revenue: 50.0, orders_pct: 50.0)
    end

    it "treats a blank utm_medium the same as absent (organic)" do
      make_yampi_order(gross: 100, utm_medium: "")

      expect(summary[:yampi_utm_breakdown][:organic]).to include(orders_count: 1)
      expect(summary[:yampi_utm_breakdown][:ads]).to include(orders_count: 0)
    end

    it "ranks top_sources and top_campaigns by orders count, summing revenue, excluding blank values" do
      make_yampi_order(gross: 100, utm_source: "facebook", utm_campaign: "blackfriday", utm_medium: "cpc")
      make_yampi_order(gross: 80, utm_source: "facebook", utm_campaign: "blackfriday", utm_medium: "cpc")
      make_yampi_order(gross: 30, utm_source: "google", utm_campaign: "search", utm_medium: "cpc")
      make_yampi_order(gross: 20) # sem UTM nenhum, não entra nos rankings

      breakdown = summary[:yampi_utm_breakdown]

      expect(breakdown[:top_sources]).to eq(
        [
          { value: "facebook", orders_count: 2, revenue: 180.0 },
          { value: "google", orders_count: 1, revenue: 30.0 }
        ]
      )
      expect(breakdown[:top_campaigns]).to eq(
        [
          { value: "blackfriday", orders_count: 2, revenue: 180.0 },
          { value: "search", orders_count: 1, revenue: 30.0 }
        ]
      )
    end

    it "excludes cancelled orders from the breakdown" do
      make_yampi_order(gross: 100, utm_medium: "cpc").update!(status: "cancelado", order_type: "cancellation")

      expect(summary[:yampi_utm_breakdown]).to eq(available: true, total_orders: 0)
    end
  end
end
