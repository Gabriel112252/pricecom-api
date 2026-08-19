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

  describe "the independent IDWorks comparison source" do
    it "includes ERP orders that have no corresponding Pricecom order" do
      now = Time.utc(2026, 8, 3, 12)
      IdworksOrder.create!(
        tenant: tenant, integration: hidrabene_integration, external_id: "88001",
        order_number: "ERP-ONLY-1", recorded_at: now, sales_channel_slug: "mercadolivre",
        value_order: 200, last_seen_at: now
      )
      IdworksOrder.create!(
        tenant: tenant, integration: hidrabene_integration, external_id: "88002",
        order_number: "ERP-ONLY-2", recorded_at: now + 1.hour, sales_channel_slug: "shopee",
        value_order: 100, last_seen_at: now
      )

      result = call_service

      expect(result.orders_count).to eq(0)
      expect(result.idworks_orders_count).to eq(2)
      expect(result.idworks_revenue_total).to eq(300.0)
      expect(result.idworks_average_ticket).to eq(150.0)
      expect(result.idworks_channel_breakdown.map { |row| row[:channel] }).to contain_exactly("Mercado Livre", "Shopee")
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

    # Planilha externa aprovada pelo Gabriel: "por marca, ranking de
    # produtos + breakdown por canal", com avulso/kit e receita aproximada
    # também cruzados na mesma linha — não é só quantidade por canal mais.
    describe "channel_breakdown per product (canal x avulso/kit x receita)" do
      it "splits a directly-sold product's quantity AND revenue by the idworks-native channel of the orders it came from" do
        product = tenant.products.create!(sku: "HID-1", name: "Produto Hidrabene", integration: hidrabene_integration)
        order1 = make_order(channel: yampi_channel, gross_value: 100, ordered_at: period_from + 1.day, idworks_sales_channel: "tiktok")
        order1.order_items.create!(product: product, sku: product.sku, name: product.name, quantity: 3, unit_price: 30)
        order2 = make_order(channel: yampi_channel, gross_value: 100, ordered_at: period_from + 1.day, idworks_sales_channel: "shopee")
        order2.order_items.create!(product: product, sku: product.sku, name: product.name, quantity: 2, unit_price: 30)

        entry = call_service.real_skus_sold.find { |e| e[:sku] == "HID-1" }

        expect(entry[:channel_breakdown]).to contain_exactly(
          { channel: "TikTok Shop", direct_qty: 3.0, kit_qty: 0.0, quantity: 3.0, revenue: 90.0 },
          { channel: "Shopee", direct_qty: 2.0, kit_qty: 0.0, quantity: 2.0, revenue: 60.0 }
        )
      end

      it "attributes exploded kit-component quantity AND a proportional share of the kit's revenue to the channel of the order it was sold through" do
        sabonete = tenant.products.create!(sku: "SABONETE", name: "Sabonete", integration: hidrabene_integration)
        kit = tenant.products.create!(sku: "KIT044", name: "Kit", is_kit: true)
        kit.kit_components.create!(component_product: sabonete, quantity: 2)

        order = make_order(channel: yampi_channel, gross_value: 100, ordered_at: period_from + 1.day, idworks_sales_channel: "mercadolivre")
        order.order_items.create!(product: kit, sku: kit.sku, name: kit.name, quantity: 3, unit_price: 100) # item revenue = 300

        entry = call_service.real_skus_sold.find { |e| e[:sku] == "SABONETE" }

        # único componente do kit -> recebe 100% da receita do item (300)
        expect(entry[:channel_breakdown]).to eq([ { channel: "Mercado Livre", direct_qty: 0.0, kit_qty: 6.0, quantity: 6.0, revenue: 300.0 } ])
      end

      # A receita de um kit é rateada proporcionalmente à quantidade real
      # de cada componente na explosão — não existe preço individual por
      # componente registrado em lugar nenhum, então isto é o máximo de
      # precisão possível (daí "Aproximada" no nome da coluna na UI).
      it "splits a kit's revenue proportionally across multiple different components by their real quantity share" do
        sabonete = tenant.products.create!(sku: "SABONETE", name: "Sabonete", integration: hidrabene_integration)
        protetor = tenant.products.create!(sku: "PROTETOR", name: "Protetor", integration: hidrabene_integration)
        kit = tenant.products.create!(sku: "KIT044", name: "Kit", is_kit: true)
        kit.kit_components.create!(component_product: sabonete, quantity: 2)
        kit.kit_components.create!(component_product: protetor, quantity: 1)

        order = make_order(channel: yampi_channel, gross_value: 100, ordered_at: period_from + 1.day, idworks_sales_channel: "tiktok")
        order.order_items.create!(product: kit, sku: kit.sku, name: kit.name, quantity: 1, unit_price: 90) # item revenue = 90

        result = call_service.real_skus_sold
        sabonete_entry = result.find { |e| e[:sku] == "SABONETE" }
        protetor_entry = result.find { |e| e[:sku] == "PROTETOR" }

        # sabonete: 2 de 3 unidades reais (2/3 de 90 = 60) | protetor: 1 de 3 (1/3 de 90 = 30)
        expect(sabonete_entry[:channel_breakdown]).to eq([ { channel: "TikTok Shop", direct_qty: 0.0, kit_qty: 2.0, quantity: 2.0, revenue: 60.0 } ])
        expect(protetor_entry[:channel_breakdown]).to eq([ { channel: "TikTok Shop", direct_qty: 0.0, kit_qty: 1.0, quantity: 1.0, revenue: 30.0 } ])
      end

      it "combines direct and kit-exploded channel quantities/revenue for the same real product in the same channel" do
        protetor = tenant.products.create!(sku: "PROTETOR", name: "Protetor", integration: hidrabene_integration)
        kit = tenant.products.create!(sku: "KIT044", name: "Kit", is_kit: true)
        kit.kit_components.create!(component_product: protetor, quantity: 1)

        direct_order = make_order(channel: yampi_channel, gross_value: 100, ordered_at: period_from + 1.day, idworks_sales_channel: "shopee")
        direct_order.order_items.create!(product: protetor, sku: protetor.sku, name: protetor.name, quantity: 4, unit_price: 20) # revenue 80
        kit_order = make_order(channel: yampi_channel, gross_value: 100, ordered_at: period_from + 1.day, idworks_sales_channel: "shopee")
        kit_order.order_items.create!(product: kit, sku: kit.sku, name: kit.name, quantity: 2, unit_price: 20) # revenue 40, 1 componente -> 100%

        entry = call_service.real_skus_sold.find { |e| e[:sku] == "PROTETOR" }

        expect(entry[:channel_breakdown]).to eq([ { channel: "Shopee", direct_qty: 4.0, kit_qty: 2.0, quantity: 6.0, revenue: 120.0 } ])
      end

      # Regressão: a soma do breakdown por canal de uma linha nunca pode
      # divergir do total_qty/direct_qty/kit_qty da mesma linha.
      it "sums to exactly total_qty (and direct_qty/kit_qty) for every entry" do
        sabonete = tenant.products.create!(sku: "SABONETE", name: "Sabonete", integration: hidrabene_integration)
        kit = tenant.products.create!(sku: "KIT044", name: "Kit", is_kit: true)
        kit.kit_components.create!(component_product: sabonete, quantity: 1)

        order1 = make_order(channel: yampi_channel, gross_value: 100, ordered_at: period_from + 1.day, idworks_sales_channel: "tiktok")
        order1.order_items.create!(product: sabonete, sku: sabonete.sku, name: sabonete.name, quantity: 5, unit_price: 20)
        order2 = make_order(channel: yampi_channel, gross_value: 100, ordered_at: period_from + 1.day, idworks_sales_channel: nil)
        order2.order_items.create!(product: kit, sku: kit.sku, name: kit.name, quantity: 3, unit_price: 20)

        call_service.real_skus_sold.each do |entry|
          expect(entry[:channel_breakdown].sum { |row| row[:quantity] }).to eq(entry[:total_qty])
          expect(entry[:channel_breakdown].sum { |row| row[:direct_qty] }).to eq(entry[:direct_qty])
          expect(entry[:channel_breakdown].sum { |row| row[:kit_qty] }).to eq(entry[:kit_qty])
        end
      end

      it "does not mix channel breakdown across the loja filter — each entry's own real component channel split" do
        hidrabene_product = tenant.products.create!(sku: "HID-1", name: "Hidrabene", integration: hidrabene_integration)
        anasol_product = tenant.products.create!(sku: "ANA-1", name: "Anasol", integration: anasol_integration)

        hid_order = make_order(channel: yampi_channel, gross_value: 100, ordered_at: period_from + 1.day, idworks_sales_channel: "tiktok")
        hid_order.order_items.create!(product: hidrabene_product, sku: hidrabene_product.sku, name: hidrabene_product.name, quantity: 2, unit_price: 50)
        ana_order = make_order(channel: yampi_channel, gross_value: 100, ordered_at: period_from + 1.day, idworks_sales_channel: "shopee")
        ana_order.order_items.create!(product: anasol_product, sku: anasol_product.sku, name: anasol_product.name, quantity: 4, unit_price: 25)

        hidrabene_result = call_service(loja: "hidrabene").real_skus_sold

        expect(hidrabene_result.map { |e| e[:sku] }).to eq([ "HID-1" ])
        expect(hidrabene_result.first[:channel_breakdown]).to eq([ { channel: "TikTok Shop", direct_qty: 2.0, kit_qty: 0.0, quantity: 2.0, revenue: 100.0 } ])
      end
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
