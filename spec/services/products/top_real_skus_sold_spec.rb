require "rails_helper"

RSpec.describe Products::TopRealSkusSold do
  let(:tenant)  { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:channel) { tenant.channels.create!(name: "Yampi", platform: "yampi") }
  let(:integration) { tenant.integrations.create!(provider: "idworks", name: "idworks", status: "connected", credentials: {}) }

  def make_order
    tenant.orders.create!(
      channel: channel, external_id: "order-#{SecureRandom.hex(4)}", order_number: SecureRandom.hex(4),
      order_type: "sale", gross_value: 100, ordered_at: 1.day.ago
    )
  end

  def items_scope
    OrderItem.joins(:order, :product).merge(Order.sales_and_refunds).where(order_id: tenant.orders.select(:id)).where(is_gift: false)
  end

  it "counts direct (non-kit) sales as-is" do
    product = tenant.products.create!(sku: "SOLO", name: "Solo")
    make_order.order_items.create!(product: product, sku: product.sku, name: product.name, quantity: 3, unit_price: 10)

    result = described_class.call(items_scope, limit: 15)

    expect(result).to eq([ { id: product.id, sku: "SOLO", name: "Solo", integration_id: nil, direct_qty: 3.0, kit_qty: 0.0, total_qty: 3.0, kit_only: false } ])
  end

  it "explodes a kit sale into its real components instead of counting the kit SKU" do
    sabonete = tenant.products.create!(sku: "SABONETE", name: "Sabonete")
    protetor = tenant.products.create!(sku: "PROTETOR", name: "Protetor")
    kit = tenant.products.create!(sku: "KIT044", name: "Kit", is_kit: true)
    kit.kit_components.create!(component_product: sabonete, quantity: 1)
    kit.kit_components.create!(component_product: protetor, quantity: 2)

    make_order.order_items.create!(product: kit, sku: kit.sku, name: kit.name, quantity: 3, unit_price: 50)

    result = described_class.call(items_scope, limit: 15)

    expect(result.map { |e| e[:sku] }).to contain_exactly("SABONETE", "PROTETOR")
    expect(result.find { |e| e[:sku] == "SABONETE" }).to include(total_qty: 3.0, kit_only: true)
    expect(result.find { |e| e[:sku] == "PROTETOR" }).to include(total_qty: 6.0, kit_only: true)
  end

  it "combines direct and kit-exploded quantities for the same real product" do
    protetor = tenant.products.create!(sku: "PROTETOR", name: "Protetor")
    kit = tenant.products.create!(sku: "KIT044", name: "Kit", is_kit: true)
    kit.kit_components.create!(component_product: protetor, quantity: 1)

    order = make_order
    order.order_items.create!(product: protetor, sku: protetor.sku, name: protetor.name, quantity: 2, unit_price: 20)
    order.order_items.create!(product: kit, sku: kit.sku, name: kit.name, quantity: 1, unit_price: 50)

    result = described_class.call(items_scope, limit: 15)

    row = result.find { |e| e[:sku] == "PROTETOR" }
    expect(row).to include(direct_qty: 2.0, kit_qty: 1.0, total_qty: 3.0, kit_only: false)
  end

  # A regra que motivou integration_id ser aplicado DEPOIS da explosão, não
  # em order_items_scope antes dela: o kit em si pode não ter
  # integration_id (idworks nem sempre tem SKU de kit no próprio catálogo),
  # mas o componente real tem — filtrar a query antes da explosão
  # descartaria a venda do kit inteira num filtro de loja.
  it "filters by integration_id on the real (leaf) component, not the kit product itself" do
    protetor = tenant.products.create!(sku: "PROTETOR", name: "Protetor", integration: integration)
    kit_sem_loja = tenant.products.create!(sku: "KIT044", name: "Kit", is_kit: true, integration: nil)
    kit_sem_loja.kit_components.create!(component_product: protetor, quantity: 1)

    make_order.order_items.create!(product: kit_sem_loja, sku: kit_sem_loja.sku, name: kit_sem_loja.name, quantity: 2, unit_price: 50)

    result = described_class.call(items_scope, limit: 15, integration_id: integration.id)

    expect(result).to eq([ { id: protetor.id, sku: "PROTETOR", name: "Protetor", integration_id: integration.id, direct_qty: 0.0, kit_qty: 2.0, total_qty: 2.0, kit_only: true } ])
  end

  it "respects the limit and sorts by total_qty descending" do
    3.times do |i|
      product = tenant.products.create!(sku: "SKU-#{i}", name: "Produto #{i}")
      make_order.order_items.create!(product: product, sku: product.sku, name: product.name, quantity: i + 1, unit_price: 10)
    end

    result = described_class.call(items_scope, limit: 2)

    expect(result.size).to eq(2)
    expect(result.map { |e| e[:sku] }).to eq([ "SKU-2", "SKU-1" ])
  end
end
