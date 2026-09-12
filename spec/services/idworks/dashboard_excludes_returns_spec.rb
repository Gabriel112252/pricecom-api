require "rails_helper"

RSpec.describe Idworks::DashboardStatsService do
  it "excludes IDWorks returns and cancelled orders from sales metrics while keeping historical rows with nil type_order" do
    tenant = Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}")
    integration = tenant.integrations.create!(provider: "idworks", name: "idworks", status: "connected", credentials: {})
    recorded_at = Time.utc(2026, 9, 10, 12)

    IdworksOrder.create!(
      tenant: tenant, integration: integration, external_id: "sale-1", order_number: "SALE1",
      recorded_at: recorded_at, type_order: "Pedido de Venda", status_order: "Nota Fiscal",
      sales_channel_slug: "mercadolivre", value_order: 100, last_seen_at: recorded_at
    )

    IdworksOrder.create!(
      tenant: tenant, integration: integration, external_id: "legacy-sale", order_number: "SALE2",
      recorded_at: recorded_at, type_order: nil, status_order: "Nota Fiscal",
      sales_channel_slug: "shopee", value_order: 50, last_seen_at: recorded_at
    )

    IdworksOrder.create!(
      tenant: tenant, integration: integration, external_id: "return-1", order_number: "DV21347399",
      recorded_at: recorded_at, type_order: "Devolução", status_order: "Nota Fiscal",
      sales_channel_slug: "idworksv2", value_order: 25_469.89, last_seen_at: recorded_at
    )

    IdworksOrder.create!(
      tenant: tenant, integration: integration, external_id: "cancelled-1", order_number: "DV21351036",
      recorded_at: recorded_at, type_order: "Pedido de Venda", status_order: "Cancelado",
      sales_channel_slug: "idworksv2", value_order: 27_264.11, last_seen_at: recorded_at
    )

    result = described_class.call(
      tenant: tenant,
      period_from: Date.new(2026, 9, 10),
      period_to: Date.new(2026, 9, 10)
    )

    expect(result.idworks_orders_count).to eq(2)
    expect(result.idworks_revenue_total).to eq(150.0)
    expect(result.idworks_average_ticket).to eq(75.0)
    expect(result.idworks_channel_breakdown.map { |row| row[:channel] }).to contain_exactly("Mercado Livre", "Shopee")
    expect(result.idworks_orders_timeseries.sum { |row| row[:count] }).to eq(2)
  end
end
