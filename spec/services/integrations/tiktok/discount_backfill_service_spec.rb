require "rails_helper"

RSpec.describe Integrations::Tiktok::DiscountBackfillService do
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

  def raw_order_detail(id:, seller_discount:, platform_discount:)
    {
      "id" => id,
      "status" => "COMPLETED",
      "create_time" => Time.zone.local(2026, 7, 1, 10, 0, 0).to_i,
      "payment" => {
        "currency" => "BRL",
        "original_total_product_price" => "118.90",
        "seller_discount" => seller_discount,
        "platform_discount" => platform_discount,
        "shipping_fee" => "0",
        "total_amount" => (118.90 - seller_discount.to_f - platform_discount.to_f).to_s
      },
      "line_items" => [
        { "sku_id" => "sku-1", "seller_sku" => "SKU-1", "product_name" => "Produto",
          "sale_price" => "70.08", "original_price" => "118.90" }
      ]
    }
  end

  it "recomputes seller_discount/platform_discount for an order stuck with the old combined discount" do
    order = tenant.orders.create!(
      channel: channel, external_id: "584933315891857248", order_number: "584933315891857248",
      status: "COMPLETED", order_type: "sale", gross_value: 118.90, discount: 48.82, cost_price: 9.84
    )

    allow(adapter).to receive(:fetch_order_details).with([ "584933315891857248" ]).and_return(
      [ raw_order_detail(id: "584933315891857248", seller_discount: "42.04", platform_discount: "6.78") ]
    )

    result = described_class.call(credential)

    expect(result.success?).to eq(true)
    order.reload
    expect(order.discount).to eq(BigDecimal("42.04"))
    expect(order.seller_discount).to eq(BigDecimal("42.04"))
    expect(order.platform_discount).to eq(BigDecimal("6.78"))
    # cost_price is recalculated from Product/order_items on reprocessing
    # (TikTok never sends cost, and this tenant has no idworks cost source
    # configured), landing on 0 here — a separate, already-known issue
    # (see the "margem por produto adiada" memory), not something this
    # discount fix touches. What matters for this test: margin reflects
    # seller_discount (42.04) only, not the old combined 48.82.
    expect(order.margin).to eq(BigDecimal("118.90") - BigDecimal("42.04"))
  end

  it "tracks progress on an IntegrationSyncLog and marks it success when every order is processed" do
    tenant.orders.create!(
      channel: channel, external_id: "1", order_number: "1", status: "COMPLETED", order_type: "sale",
      gross_value: 100, discount: 50
    )
    allow(adapter).to receive(:fetch_order_details).with([ "1" ]).and_return(
      [ raw_order_detail(id: "1", seller_discount: "40.00", platform_discount: "10.00") ]
    )

    described_class.call(credential)

    log = IntegrationSyncLog.find_by!(tenant: tenant, action: described_class::ACTION)
    expect(log.status).to eq("success")
    expect(log.metadata["processed_count"]).to eq(1)
    expect(log.metadata["error_count"]).to eq(0)
    expect(log.metadata["total_orders"]).to eq(1)
  end

  it "resumes from the last processed order id of a pending log instead of restarting" do
    order1 = tenant.orders.create!(
      channel: channel, external_id: "1", order_number: "1", status: "COMPLETED", order_type: "sale",
      gross_value: 100, discount: 50
    )
    tenant.orders.create!(
      channel: channel, external_id: "2", order_number: "2", status: "COMPLETED", order_type: "sale",
      gross_value: 100, discount: 50
    )
    IntegrationSyncLog.create!(
      tenant: tenant, direction: "inbound", action: described_class::ACTION, status: "pending",
      started_at: 1.hour.ago,
      metadata: { total_orders: 2, processed_count: 1, error_count: 0, error_samples: [], last_order_id: order1.id }
    )

    allow(adapter).to receive(:fetch_order_details).with([ "2" ]).and_return(
      [ raw_order_detail(id: "2", seller_discount: "40.00", platform_discount: "10.00") ]
    )

    described_class.call(credential)

    expect(adapter).to have_received(:fetch_order_details).with([ "2" ]).once
    expect(adapter).not_to have_received(:fetch_order_details).with([ "1" ])

    log = IntegrationSyncLog.find_by!(tenant: tenant, action: described_class::ACTION)
    expect(log.status).to eq("success")
    expect(log.metadata["processed_count"]).to eq(2)
  end

  it "records an error and keeps going when TikTok doesn't return a detail for an order" do
    tenant.orders.create!(
      channel: channel, external_id: "1", order_number: "1", status: "COMPLETED", order_type: "sale",
      gross_value: 100, discount: 50
    )
    allow(adapter).to receive(:fetch_order_details).and_return([])

    result = described_class.call(credential)

    expect(result.metadata[:error_count]).to eq(1)
    log = IntegrationSyncLog.find_by!(tenant: tenant, action: described_class::ACTION)
    expect(log.status).to eq("error")
    expect(log.metadata["error_samples"].first).to include("order detail not returned by TikTok")
  end

  it "skips when the tenant has no tiktok channel" do
    tenant_without_channel = Tenant.create!(name: "Sem TikTok", slug: "sem-tiktok-#{SecureRandom.hex(4)}")
    credential_without_channel = tenant_without_channel.channel_credentials.create!(
      channel: "tiktok", status: "active",
      credentials: { app_key: "key", app_secret: "secret", access_token: "tok", shop_cipher: "cipher" }
    )
    allow(Integrations::TiktokAdapter).to receive(:new).with(credential_without_channel.credentials).and_return(adapter)

    result = described_class.call(credential_without_channel)

    expect(result.skipped?).to eq(true)
  end
end
