require "rails_helper"

RSpec.describe Idworks::DashboardStatsService do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:yampi_channel)  { tenant.channels.create!(name: "Yampi", platform: "yampi") }
  let(:tiktok_channel) { tenant.channels.create!(name: "TikTok Shop", platform: "tiktok") }

  let(:hidrabene_integration) do
    tenant.integrations.create!(provider: "idworks", name: "idworks", status: "connected", credentials: {})
  end
  let(:anasol_integration) do
    tenant.integrations.create!(provider: "idworks", name: "idworks Anasol", status: "connected", credentials: {})
  end

  let(:period_from) { Date.new(2026, 8, 1) }
  let(:period_to)   { Date.new(2026, 8, 7) }

  def make_order(channel:, gross_value:, ordered_at:, status: nil, idworks_sales_channel: nil)
    tenant.orders.create!(
      channel: channel, external_id: "order-#{SecureRandom.hex(4)}", order_number: SecureRandom.hex(4),
      order_type: "sale", status: status, gross_value: gross_value, ordered_at: ordered_at,
      idworks_sales_channel: idworks_sales_channel
    )
  end

  def call_service(loja: nil)
    described_class.call(tenant: tenant, period_from: period_from, period_to: period_to, loja: loja)
  end

  describe "revenue_total / orders_count" do
    it "sums effective revenue and counts orders in the period, excluding unpaid orders" do
      make_order(channel: yampi_channel, gross_value: 100, ordered_at: period_from + 1.day)
      make_order(channel: yampi_channel, gross_value: 200, ordered_at: period_from + 2.days)
      make_order(channel: yampi_channel, gross_value: 999, ordered_at: period_from + 2.days, status: "unpaid")
      make_order(channel: yampi_channel, gross_value: 50, ordered_at: period_from - 5.days) # fora do período

      result = call_service

      expect(result.orders_count).to eq(2)
      expect(result.revenue_total).to eq(300.0)
      expect(result.average_ticket).to eq(150.0)
    end
  end

  describe "loja filter" do
    it "narrows orders to only those whose items include a product from that loja's integration" do
      hidrabene_product = tenant.products.create!(sku: "HID-1", name: "Produto Hidrabene", integration: hidrabene_integration)
      anasol_product     = tenant.products.create!(sku: "ANA-1", name: "Produto Anasol", integration: anasol_integration)

      order_hidrabene = make_order(channel: yampi_channel, gross_value: 100, ordered_at: period_from + 1.day)
      order_hidrabene.order_items.create!(product: hidrabene_product, sku: hidrabene_product.sku, name: hidrabene_product.name, quantity: 1, unit_price: 100)

      order_anasol = make_order(channel: yampi_channel, gross_value: 50, ordered_at: period_from + 1.day)
      order_anasol.order_items.create!(product: anasol_product, sku: anasol_product.sku, name: anasol_product.name, quantity: 1, unit_price: 50)

      expect(call_service(loja: "hidrabene").orders_count).to eq(1)
      expect(call_service(loja: "hidrabene").revenue_total).to eq(100.0)
      expect(call_service(loja: "anasol").orders_count).to eq(1)
      expect(call_service(loja: "anasol").revenue_total).to eq(50.0)
      expect(call_service.orders_count).to eq(2)
    end

    it "returns empty results for a loja whose integration hasn't been connected yet" do
      make_order(channel: yampi_channel, gross_value: 100, ordered_at: period_from + 1.day)

      result = call_service(loja: "anasol")

      expect(result.orders_count).to eq(0)
      expect(result.revenue_total).to eq(0.0)
      expect(result.top_products).to eq([])
    end
  end

  describe "revenue_by_loja" do
    it "always returns the full breakdown regardless of the loja filter, bucketing untagged products separately" do
      hidrabene_product = tenant.products.create!(sku: "HID-1", name: "Produto Hidrabene", integration: hidrabene_integration)
      untagged_product  = tenant.products.create!(sku: "SEM-LOJA", name: "Produto sem loja")

      order1 = make_order(channel: yampi_channel, gross_value: 100, ordered_at: period_from + 1.day)
      order1.order_items.create!(product: hidrabene_product, sku: hidrabene_product.sku, name: hidrabene_product.name, quantity: 1, unit_price: 100)

      order2 = make_order(channel: yampi_channel, gross_value: 40, ordered_at: period_from + 1.day)
      order2.order_items.create!(product: untagged_product, sku: untagged_product.sku, name: untagged_product.name, quantity: 1, unit_price: 40)

      breakdown = call_service(loja: "hidrabene").revenue_by_loja

      expect(breakdown["hidrabene"]).to eq(100.0)
      expect(breakdown["anasol"]).to eq(0.0)
      expect(breakdown["nao_identificado"]).to eq(40.0)
    end
  end

  describe "top_products" do
    it "ranks by quantity sold, limited to 10, respecting the loja filter" do
      product = tenant.products.create!(sku: "HID-1", name: "Produto Hidrabene", integration: hidrabene_integration)
      order = make_order(channel: yampi_channel, gross_value: 300, ordered_at: period_from + 1.day)
      order.order_items.create!(product: product, sku: product.sku, name: product.name, quantity: 3, unit_price: 100)

      top = call_service(loja: "hidrabene").top_products

      expect(top).to eq([ { sku: "HID-1", name: "Produto Hidrabene", quantity: 3.0, revenue: 300.0 } ])
    end
  end

  # channel_breakdown desta aba agrupa por orders.idworks_sales_channel
  # (canal nativo do idworks — CONFIRMADO 2026-08-17 via SalesChannelLogoUrl,
  # ver Idworks::DashboardStatsService's class comment), não channels.name
  # do Pricecom — as outras abas do dashboard continuam com channels.name,
  # que não cobre Mercado Livre (sem integração direta ainda).
  describe "channel_breakdown" do
    it "groups by the idworks-native sales channel, not the Pricecom Channel — covers a channel with no Pricecom integration (ML)" do
      make_order(channel: yampi_channel, gross_value: 100, ordered_at: period_from + 1.day, idworks_sales_channel: "tiktok")
      make_order(channel: yampi_channel, gross_value: 100, ordered_at: period_from + 1.day, idworks_sales_channel: "shopee")
      make_order(channel: yampi_channel, gross_value: 100, ordered_at: period_from + 1.day, idworks_sales_channel: "mercadolivre")

      breakdown = call_service.channel_breakdown

      expect(breakdown.map { |row| row[:channel] }).to contain_exactly("TikTok Shop", "Shopee", "Mercado Livre")
    end

    it "maps a shopify order before the 2026-06-15 cutoff to 'Shopify'" do
      make_order(channel: yampi_channel, gross_value: 100, ordered_at: Date.new(2026, 6, 10), idworks_sales_channel: "shopify")

      result = described_class.call(tenant: tenant, period_from: Date.new(2026, 6, 1), period_to: Date.new(2026, 6, 30))

      expect(result.channel_breakdown.map { |row| row[:channel] }).to eq([ "Shopify" ])
    end

    it "maps a shopify order on/after the 2026-06-15 cutoff to 'Yampi'" do
      make_order(channel: yampi_channel, gross_value: 100, ordered_at: Date.new(2026, 6, 15), idworks_sales_channel: "shopify")

      result = described_class.call(tenant: tenant, period_from: Date.new(2026, 6, 1), period_to: Date.new(2026, 6, 30))

      expect(result.channel_breakdown.map { |row| row[:channel] }).to eq([ "Yampi" ])
    end

    it "buckets a nil idworks_sales_channel or an unmapped slug (new channel we haven't seen) as 'Não identificado'" do
      make_order(channel: yampi_channel, gross_value: 100, ordered_at: period_from + 1.day, idworks_sales_channel: nil)
      make_order(channel: yampi_channel, gross_value: 50, ordered_at: period_from + 1.day, idworks_sales_channel: "amazon")

      breakdown = call_service.channel_breakdown

      expect(breakdown.map { |row| row[:channel] }).to eq([ "Não identificado" ])
      expect(breakdown.first[:orders_count]).to eq(2)
    end

    # Regressão: o CASE de agrupamento tem um ELSE — nenhum pedido pode
    # ficar de fora da soma, mesmo com canal nulo/desconhecido.
    it "never drops an order — the sum of orders_count across the breakdown matches the raw orders_count" do
      make_order(channel: yampi_channel, gross_value: 100, ordered_at: period_from + 1.day, idworks_sales_channel: "tiktok")
      make_order(channel: yampi_channel, gross_value: 100, ordered_at: period_from + 1.day, idworks_sales_channel: nil)
      make_order(channel: yampi_channel, gross_value: 100, ordered_at: period_from + 1.day, idworks_sales_channel: "shopee")

      result = call_service

      expect(result.channel_breakdown.sum { |row| row[:orders_count] }).to eq(result.orders_count)
    end

    it "still mirrors sales_by_channel's row shape (net_revenue, orders_count, average_ticket, share_percentage)" do
      make_order(channel: yampi_channel, gross_value: 100, ordered_at: period_from + 1.day, idworks_sales_channel: "tiktok")
      make_order(channel: yampi_channel, gross_value: 100, ordered_at: period_from + 1.day, idworks_sales_channel: "shopee")

      breakdown = call_service.channel_breakdown
      tiktok_row = breakdown.find { |row| row[:channel] == "TikTok Shop" }

      expect(tiktok_row[:orders_count]).to eq(1)
      expect(tiktok_row[:net_revenue]).to eq(100.0)
      expect(tiktok_row[:average_ticket]).to eq(100.0)
      expect(tiktok_row[:share_percentage]).to eq(50.0)
    end
  end

  # Diferente de top_products (ranqueia pelo SKU literal do order_item,
  # kit incluído como 1 unidade do próprio kit) — real_skus_sold explode a
  # venda de kit nos componentes que de fato saíram do estoque.
  describe "real_skus_sold" do
    it "explodes a kit sale into its real components, not the kit SKU itself" do
      sabonete = tenant.products.create!(sku: "SABONETE", name: "Sabonete", integration: hidrabene_integration)
      kit = tenant.products.create!(sku: "KIT044", name: "Kit", is_kit: true)
      kit.kit_components.create!(component_product: sabonete, quantity: 2)

      order = make_order(channel: yampi_channel, gross_value: 100, ordered_at: period_from + 1.day)
      order.order_items.create!(product: kit, sku: kit.sku, name: kit.name, quantity: 3, unit_price: 100)

      result = call_service.real_skus_sold

      expect(result.map { |e| e[:sku] }).to eq([ "SABONETE" ])
      expect(result.first[:total_qty]).to eq(6.0) # 3 kits x 2 componentes
      expect(result.first[:kit_only]).to eq(true)
    end

    it "filters by loja on the real component's own integration, even when the kit product has none" do
      protetor = tenant.products.create!(sku: "PROTETOR", name: "Protetor", integration: hidrabene_integration)
      kit_sem_loja = tenant.products.create!(sku: "KIT-X", name: "Kit sem loja direta", is_kit: true)
      kit_sem_loja.kit_components.create!(component_product: protetor, quantity: 1)

      order = make_order(channel: yampi_channel, gross_value: 100, ordered_at: period_from + 1.day)
      order.order_items.create!(product: kit_sem_loja, sku: kit_sem_loja.sku, name: kit_sem_loja.name, quantity: 2, unit_price: 50)

      hidrabene_result = call_service(loja: "hidrabene").real_skus_sold
      anasol_result = call_service(loja: "anasol").real_skus_sold

      expect(hidrabene_result.map { |e| e[:sku] }).to eq([ "PROTETOR" ])
      expect(anasol_result).to eq([])
    end
  end

  describe "orders_timeseries" do
    it "buckets orders per day and channel" do
      make_order(channel: yampi_channel, gross_value: 100, ordered_at: period_from + 1.day)
      make_order(channel: yampi_channel, gross_value: 100, ordered_at: period_from + 1.day)

      timeseries = call_service.orders_timeseries

      expect(timeseries).to eq([ { date: (period_from + 1.day).iso8601, channel: "Yampi", count: 2 } ])
    end
  end
end
