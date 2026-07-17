require "rails_helper"

RSpec.describe Integrations::Tiktok::ShippingFeeAuditBackfillService do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:channel) { Channel.ensure_for!(tenant, "tiktok") }
  let(:credential) do
    tenant.channel_credentials.create!(
      channel: "tiktok",
      status: "active",
      credentials: { app_key: "key", app_secret: "secret", access_token: "tok", shop_cipher: "cipher" }
    )
  end
  let(:adapter) { instance_double(Integrations::TiktokAdapter) }

  before do
    allow(Integrations::TiktokAdapter).to receive(:new).with(credential.credentials).and_return(adapter)
  end

  it "fetches order details for paid TikTok orders missing original_shipping_fee and rebuilds freight margin" do
    order = tenant.orders.create!(
      channel: channel,
      external_id: "584809097368274473",
      order_number: "584809097368274473",
      status: "COMPLETED",
      order_type: "sale",
      gross_value: 108.64,
      freight: 8.64,
      original_shipping_fee: nil,
      ordered_at: Time.zone.local(2026, 7, 1, 10, 0, 0)
    )
    tenant.orders.create!(
      channel: channel,
      external_id: "584809083562394903",
      order_number: "584809083562394903",
      status: "CANCELLED",
      order_type: "cancellation",
      gross_value: 100,
      freight: 0,
      original_shipping_fee: 18.64,
      ordered_at: Time.zone.local(2026, 7, 1, 11, 0, 0)
    )

    allow(adapter).to receive(:fetch_order_details).with([ "584809097368274473" ]).and_return(
      [
        {
          "id" => "584809097368274473",
          "status" => "COMPLETED",
          "create_time" => Time.zone.local(2026, 7, 1, 10, 0, 0).to_i,
          "payment" => {
            "currency" => "BRL",
            "original_total_product_price" => "100.00",
            "seller_discount" => "0",
            "platform_discount" => "0",
            "shipping_fee" => "8.64",
            "original_shipping_fee" => "18.64",
            "shipping_fee_platform_discount" => "10.00",
            "shipping_fee_seller_discount" => "0",
            "total_amount" => "108.64"
          },
          "line_items" => [
            {
              "sku_id" => "sku-1",
              "seller_sku" => "SKU-1",
              "product_name" => "Produto",
              "sale_price" => "100.00",
              "original_price" => "100.00"
            }
          ]
        }
      ]
    )

    result = described_class.call(credential)

    expect(result.success?).to eq(true)
    expect(order.reload.original_shipping_fee).to eq(BigDecimal("18.64"))
    expect(order.freight).to eq(BigDecimal("8.64"))

    daily = tenant.freight_margin_dailies.find_by!(channel: channel, date: Date.new(2026, 7, 1))
    expect(daily.order_count).to eq(1)
    expect(daily.freight_charged).to eq(BigDecimal("8.64"))
    expect(daily.freight_cost).to eq(BigDecimal("18.64"))
    expect(daily.margin_value).to eq(BigDecimal("-10.00"))
    expect(result.metadata[:filled_count]).to eq(1)
    expect(result.metadata[:eligible_count]).to eq(1)
  end

  it "records detail misses without failing the whole backfill" do
    tenant.orders.create!(
      channel: channel,
      external_id: "584809097368274473",
      order_number: "584809097368274473",
      status: "DELIVERED",
      order_type: "sale",
      gross_value: 108.64,
      freight: 8.64,
      original_shipping_fee: nil,
      ordered_at: Time.zone.local(2026, 7, 1, 10, 0, 0)
    )
    allow(adapter).to receive(:fetch_order_details).and_return([])

    result = described_class.call(credential)

    expect(result.success?).to eq(true)
    expect(result.metadata[:detail_missing_count]).to eq(1)
    expect(result.metadata[:filled_count]).to eq(0)
  end
end
