require "rails_helper"

RSpec.describe Integrations::Tiktok::UnpaidOrdersSyncService do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:credential) do
    tenant.channel_credentials.create!(
      channel: "tiktok",
      status: "active",
      polling_enabled: true,
      credentials: { app_key: "key", app_secret: "secret", access_token: "tok", shop_cipher: "cipher" }
    )
  end
  let(:adapter) { instance_double(Integrations::TiktokAdapter) }

  let(:unpaid_order_payload) do
    {
      "id" => "580100000000000099",
      "status" => "UNPAID",
      "create_time" => 2.hours.ago.to_i,
      "payment" => {
        "currency" => "BRL",
        "original_total_product_price" => "100.00",
        "seller_discount" => "10.00",
        "platform_discount" => "0",
        "shipping_fee" => "8.00",
        "original_shipping_fee" => "12.00",
        "shipping_fee_seller_discount" => "4.00",
        "shipping_fee_platform_discount" => "0",
        "total_amount" => "98.00"
      },
      "line_items" => [
        { "sku_id" => "sku-1", "seller_sku" => "CAMISETA-P", "product_name" => "Camiseta", "sale_price" => "90.00", "original_price" => "100.00" }
      ]
    }
  end

  before do
    allow(Integrations::TiktokAdapter).to receive(:new).and_return(adapter)
  end

  it "upserts the UNPAID order (status unpaid, out of revenue) and materializes it as an abandoned cart" do
    allow(adapter).to receive(:fetch_orders_page).and_return(
      { "orders" => [ unpaid_order_payload ], "next_page_token" => nil }
    )

    result = described_class.call(credential, trigger: "spec")

    expect(result.success?).to eq(true)
    expect(adapter).to have_received(:fetch_orders_page).with(
      hash_including(filters: hash_including(order_status: "UNPAID"))
    )

    order = tenant.orders.find_by!(external_id: "580100000000000099")
    expect(order.status).to eq("unpaid")
    expect(order.channel.platform).to eq("tiktok")
    expect(order.freight).to eq(BigDecimal("8.00"))
    expect(order.original_shipping_fee).to eq(BigDecimal("12.00"))
    expect(order.shipping_fee_seller_discount).to eq(BigDecimal("4.00"))

    cart = tenant.carts.find_by!(external_id: "580100000000000099")
    expect(cart.channel.platform).to eq("tiktok")
    expect(cart.status).to eq("abandoned")
    # total = gross (108.00) - discount (10.00) = valor pago do pedido UNPAID
    expect(cart.total).to eq(BigDecimal("98.00"))
    expect(cart.raw_payload["items"]).to eq([ { "sku" => "CAMISETA-P", "name" => "Camiseta", "quantity" => 1 } ])

    log = tenant.integration_sync_logs.find_by!(action: "tiktok_unpaid_orders_sync")
    expect(log.status).to eq("success")
    expect(log.metadata).to include("orders_upserted" => 1, "carts_upserted" => 1)
  end

  it "never bounces an already-converted cart back to abandoned on re-sync" do
    channel = Channel.ensure_for!(tenant, "tiktok")
    converted_order = tenant.orders.create!(
      channel: channel, external_id: "580100000000000099", order_number: "580100000000000099",
      order_type: "sale", status: "AWAITING_SHIPMENT", gross_value: 98, ordered_at: 2.hours.ago
    )
    tenant.carts.create!(
      channel: channel, external_id: "580100000000000099", total: 98,
      status: "converted", converted_order: converted_order, abandoned_at: 2.hours.ago
    )
    allow(adapter).to receive(:fetch_orders_page).and_return(
      { "orders" => [ unpaid_order_payload ], "next_page_token" => nil }
    )

    described_class.call(credential, trigger: "spec")

    expect(tenant.carts.find_by!(external_id: "580100000000000099").status).to eq("converted")
  end

  it "skips when polling is disabled" do
    credential.update!(polling_enabled: false)
    allow(adapter).to receive(:fetch_orders_page)

    result = described_class.call(credential, trigger: "spec")

    expect(result.skipped?).to eq(true)
    expect(adapter).not_to have_received(:fetch_orders_page)
  end
end
