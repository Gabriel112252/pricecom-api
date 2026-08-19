require "rails_helper"

RSpec.describe Integrations::Idworks::OrderSnapshotService do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:integration) do
    tenant.integrations.create!(provider: "idworks", name: "idworks", status: "connected", credentials: {})
  end

  it "stores matched and unmatched IDWorks orders independently from Pricecom orders" do
    raw_orders = [
      {
        idworks_order_id: "88001", order_ref: "555001", recorded_at: Time.utc(2026, 8, 1, 10),
        status_order: "Fechado", id_status_order: 1, sales_channel_slug: "shopee",
        value_shipping: BigDecimal("10"), value_product: BigDecimal("90"),
        value_order: BigDecimal("100"), value_paid: BigDecimal("100")
      },
      {
        idworks_order_id: "88002", order_ref: "ERP-ONLY", recorded_at: Time.utc(2026, 8, 2, 10),
        sales_channel_slug: "mercadolivre", value_order: BigDecimal("200")
      }
    ]

    expect {
      described_class.persist!(integration, raw_orders, seen_at: Time.utc(2026, 8, 3))
    }.to change(IdworksOrder, :count).by(2)

    expect(IdworksOrder.find_by(external_id: "88002")).to have_attributes(
      order_number: "ERP-ONLY",
      sales_channel_slug: "mercadolivre",
      value_order: BigDecimal("200")
    )
  end

  it "upserts a repeated IDWorks order without duplicating it" do
    raw_order = { idworks_order_id: "88001", order_ref: "555001", value_order: BigDecimal("100") }

    described_class.persist!(integration, [raw_order], seen_at: Time.utc(2026, 8, 1))
    described_class.persist!(integration, [raw_order.merge(value_order: BigDecimal("120"))], seen_at: Time.utc(2026, 8, 2))

    expect(IdworksOrder.where(integration: integration).count).to eq(1)
    expect(IdworksOrder.find_by(external_id: "88001").value_order).to eq(BigDecimal("120"))
  end
end
