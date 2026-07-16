require "rails_helper"

RSpec.describe Integrations::Lucrofrete::OrdersSyncService do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:channel) { tenant.channels.create!(name: "Yampi", platform: "yampi") }
  let(:credential) do
    tenant.channel_credentials.create!(
      channel: "lucrofrete",
      status: "active",
      credentials: { email: "user@example.com", password: "secret" }
    )
  end
  let(:client) { instance_double(Integrations::LucrofreteClient) }

  before do
    DataSourceConfig.ensure_default!(tenant, "freight", "lucrofrete")
    allow(Integrations::LucrofreteClient).to receive(:new).with(credential).and_return(client)
  end

  it "updates local real_freight_cost and aggregates matched report orders for the dashboard" do
    order = tenant.orders.create!(
      channel: channel,
      external_id: "1517221536257631",
      order_number: "1517221536257631",
      ordered_at: Time.zone.local(2026, 7, 16, 16, 33, 45),
      gross_value: 40.80,
      freight: 5.90,
      order_type: "sale"
    )
    allow(client).to receive(:fetch_orders_report).and_return(
      {
        "total" => 2,
        "page" => 1,
        "per_page" => 50,
        "orders" => [
          {
            "id" => "0c48f77b-8480-4a1e-825f-daa8330f304b",
            "order_number" => 1517221536257631,
            "order_created_at" => "2026-07-16T19:33:45.000Z",
            "freight_charged" => 5.90,
            "freight_cost" => 14.85,
            "margin_value" => -8.95,
            "is_free_shipping" => false,
            "match_status" => "matched",
            "quote_log_id" => "91516d40-77db-43c4-b3d1-b76b53345fcf"
          },
          {
            "id" => "76f39501-6ee8-4bb1-bceb-c601af17c5a2",
            "order_number" => 1517221900694782,
            "order_created_at" => "2026-07-16T19:31:19.000Z",
            "freight_charged" => 9.90,
            "freight_cost" => 13.95,
            "margin_value" => -4.05,
            "is_free_shipping" => false,
            "match_status" => "matched",
            "quote_log_id" => "19c994f7-3be4-475d-9f51-38c6d8ccbad8"
          }
        ]
      }
    )

    result = described_class.call(
      credential,
      mode: "incremental",
      start_date: Date.new(2026, 7, 16),
      end_date: Date.new(2026, 7, 16),
      trigger: "spec"
    )

    expect(result.success?).to eq(true)
    expect(order.reload.real_freight_cost).to eq(BigDecimal("14.85"))

    daily = tenant.freight_margin_dailies.find_by!(channel: channel, date: Date.new(2026, 7, 16))
    expect(daily.order_count).to eq(2)
    expect(daily.freight_charged).to eq(BigDecimal("15.80"))
    expect(daily.freight_cost).to eq(BigDecimal("28.80"))
    expect(daily.margin_value).to eq(BigDecimal("-13.00"))

    report = tenant.lucrofrete_order_reports.find_by!(lucrofrete_order_id: "0c48f77b-8480-4a1e-825f-daa8330f304b")
    expect(report.order).to eq(order)
    expect(report.order_number).to eq("1517221536257631")
    expect(report.freight_charged).to eq(BigDecimal("5.90"))
    expect(report.freight_cost).to eq(BigDecimal("14.85"))
    expect(report.margin_value).to eq(BigDecimal("-8.95"))
    expect(report.match_status).to eq("matched")
  end

  it "matches non-yampi orders tenant-wide and aggregates their freight margin under the order's channel" do
    tiktok_channel = tenant.channels.create!(name: "TikTok Shop", platform: "tiktok")
    tiktok_order = tenant.orders.create!(
      channel: tiktok_channel,
      external_id: "580100000000000001",
      order_number: "580100000000000001",
      ordered_at: Time.zone.local(2026, 7, 16, 10, 0, 0),
      gross_value: 126.64,
      freight: 6.84, # payment.shipping_fee cobrado do cliente
      order_type: "sale"
    )
    allow(client).to receive(:fetch_orders_report).and_return(
      {
        "total" => 1,
        "page" => 1,
        "per_page" => 50,
        "orders" => [
          {
            "id" => "aa48f77b-8480-4a1e-825f-daa8330f304c",
            "order_number" => "580100000000000001",
            "order_created_at" => "2026-07-16T13:00:00.000Z",
            "freight_charged" => 0.0, # LucroFrete não conhece o frete cobrado pelo TikTok
            "freight_cost" => 14.85,
            "margin_value" => -14.85,
            "is_free_shipping" => false,
            "match_status" => "matched",
            "quote_log_id" => "91516d40-77db-43c4-b3d1-b76b53345aaa"
          }
        ]
      }
    )

    result = described_class.call(
      credential,
      mode: "incremental",
      start_date: Date.new(2026, 7, 16),
      end_date: Date.new(2026, 7, 16),
      trigger: "spec"
    )

    expect(result.success?).to eq(true)
    expect(tiktok_order.reload.real_freight_cost).to eq(BigDecimal("14.85"))

    daily = tenant.freight_margin_dailies.find_by!(channel: tiktok_channel, date: Date.new(2026, 7, 16))
    expect(daily.order_count).to eq(1)
    expect(daily.freight_charged).to eq(BigDecimal("6.84"))  # orders.freight, não o valor do LucroFrete
    expect(daily.freight_cost).to eq(BigDecimal("14.85"))
    expect(daily.margin_value).to eq(BigDecimal("-8.01"))
    expect(tenant.freight_margin_dailies.where(channel: channel)).to be_empty
  end

  it "skips without calling LucroFrete when freight source is not lucrofrete" do
    allow(client).to receive(:fetch_orders_report)
    tenant.data_source_configs.find_by!(data_type: "freight").update!(source: "idworks")

    result = described_class.call(
      credential,
      mode: "incremental",
      start_date: Date.new(2026, 7, 16),
      end_date: Date.new(2026, 7, 16),
      trigger: "spec"
    )

    expect(result.skipped?).to eq(true)
    expect(client).not_to have_received(:fetch_orders_report)
    expect(tenant.freight_margin_dailies.count).to eq(0)
    expect(tenant.lucrofrete_order_reports.count).to eq(0)
  end
end
