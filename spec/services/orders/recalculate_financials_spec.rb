require "rails_helper"

RSpec.describe Orders::RecalculateFinancials do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:channel) { tenant.channels.create!(name: "Yampi", platform: "yampi", commission_pct: 10, commission_fixed: 2) }
  let(:product) { tenant.products.create!(sku: "SKU-1", name: "Produto", cost_price: 40) }
  let(:order) do
    tenant.orders.create!(
      channel: channel,
      external_id: "ORDER-1",
      order_number: "ORDER-1",
      gross_value: 200,
      freight: 10,
      discount: 5,
      ordered_at: Time.current,
      order_type: "sale"
    )
  end

  before do
    ChannelOperationalCost.create!(product: product, channel: channel, cost: 3)
    order.order_items.create!(
      product: product,
      sku: product.sku,
      name: product.name,
      quantity: 2,
      unit_price: 100,
      unit_cost: 40,
      is_gift: false
    )
  end

  it "recalculates the order without running audits when run_audit is false" do
    expect(Audits::DetectOrderConflicts).not_to receive(:call)

    expect {
      described_class.call(order, run_audit: false)
    }.not_to raise_error

    order.reload
    expect(order.cost_price).to eq(BigDecimal("80.0"))
    expect(order.commission).to eq(BigDecimal("22.0"))
    expect(order.operational_cost).to eq(BigDecimal("3.0"))
    expect(order.margin).to eq(BigDecimal("80.0"))
  end

  it "runs audits by default" do
    expect(Audits::DetectOrderConflicts).to receive(:call).with(order).once

    described_class.call(order)
  end

  it "looks up operational costs for every item in a single batched query, not one per item" do
    other_product = tenant.products.create!(sku: "SKU-2", name: "Outro Produto", cost_price: 20)
    ChannelOperationalCost.create!(product: other_product, channel: channel, cost: 5)
    order.order_items.create!(
      product: other_product, sku: other_product.sku, name: other_product.name,
      quantity: 1, unit_price: 50, unit_cost: 20, is_gift: false
    )

    expect(ChannelOperationalCost).to receive(:where).once.and_call_original
    expect(ChannelOperationalCost).not_to receive(:find_by)

    described_class.call(order, run_audit: false)

    # flat cost per item (not multiplied by quantity): 3 (product) + 5 (other_product)
    expect(order.reload.operational_cost).to eq(BigDecimal("8.0"))
  end
end
