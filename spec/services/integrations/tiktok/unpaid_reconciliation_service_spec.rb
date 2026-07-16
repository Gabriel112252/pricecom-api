require "rails_helper"

RSpec.describe Integrations::Tiktok::UnpaidReconciliationService do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:channel) { Channel.ensure_for!(tenant, "tiktok") }
  let(:credential) do
    tenant.channel_credentials.create!(
      channel: "tiktok",
      status: "active",
      polling_enabled: true,
      credentials: { app_key: "key", app_secret: "secret", access_token: "tok", shop_cipher: "cipher" }
    )
  end
  let(:adapter) { instance_double(Integrations::TiktokAdapter) }

  before do
    allow(Integrations::TiktokAdapter).to receive(:new).and_return(adapter)
  end

  def make_unpaid_order(external_id, ordered_at: 2.hours.ago)
    order = tenant.orders.create!(
      channel: channel, external_id: external_id, order_number: external_id,
      order_type: "sale", status: "unpaid", gross_value: 98, ordered_at: ordered_at
    )
    cart = tenant.carts.create!(
      channel: channel, external_id: external_id, total: 98,
      status: "abandoned", abandoned_at: ordered_at
    )
    [ order, cart ]
  end

  def detail_payload(external_id, status)
    {
      "id" => external_id,
      "status" => status,
      "create_time" => 2.hours.ago.to_i,
      "payment" => {
        "original_total_product_price" => "100.00",
        "seller_discount" => "10.00",
        "platform_discount" => "0",
        "shipping_fee" => "8.00",
        "total_amount" => "98.00"
      },
      "line_items" => []
    }
  end

  it "marks the order and its cart converted when the detail shows a PAID+ status" do
    order, cart = make_unpaid_order("58010000000000001")
    allow(adapter).to receive(:fetch_order_details).with([ "58010000000000001" ])
      .and_return([ detail_payload("58010000000000001", "AWAITING_SHIPMENT") ])

    result = described_class.call(credential, trigger: "spec")

    expect(result.success?).to eq(true)
    expect(order.reload.status).to eq("AWAITING_SHIPMENT")
    expect(cart.reload.status).to eq("converted")
    expect(cart.converted_order_id).to eq(order.id)

    log = tenant.integration_sync_logs.find_by!(action: "tiktok_unpaid_reconciliation")
    expect(log.metadata).to include("converted_count" => 1, "still_unpaid_count" => 0)
  end

  it "keeps the cart abandoned when the order was cancelled (definitive abandonment)" do
    order, cart = make_unpaid_order("58010000000000002")
    allow(adapter).to receive(:fetch_order_details)
      .and_return([ detail_payload("58010000000000002", "CANCELLED") ])

    described_class.call(credential, trigger: "spec")

    expect(order.reload.status).to eq("CANCELLED")
    expect(order.order_type).to eq("cancellation")
    expect(cart.reload.status).to eq("abandoned")
  end

  it "keeps a fresh still-unpaid order in the queue for the next run" do
    order, cart = make_unpaid_order("58010000000000003")
    allow(adapter).to receive(:fetch_order_details)
      .and_return([ detail_payload("58010000000000003", "UNPAID") ])

    result = described_class.call(credential, trigger: "spec")

    expect(order.reload.status).to eq("unpaid")
    expect(cart.reload.status).to eq("abandoned")
    expect(result.metadata).to include(still_unpaid_count: 1, status_unknown_count: 0)
  end

  it "ages out to status_unknown (and stops requerying) after MAX_PENDING_DAYS" do
    stale_order, cart = make_unpaid_order("58010000000000004", ordered_at: (described_class::MAX_PENDING_DAYS + 1).days.ago)
    missing_order, = make_unpaid_order("58010000000000005", ordered_at: (described_class::MAX_PENDING_DAYS + 1).days.ago)
    allow(adapter).to receive(:fetch_order_details)
      .and_return([ detail_payload("58010000000000004", "UNPAID") ]) # o outro sumiu da API

    described_class.call(credential, trigger: "spec")

    expect(stale_order.reload.status).to eq("status_unknown")
    expect(missing_order.reload.status).to eq("status_unknown")
    expect(cart.reload.status).to eq("abandoned")

    # Fora da fila: a próxima execução não reconsulta ninguém.
    allow(adapter).to receive(:fetch_order_details).and_return([])
    described_class.call(credential, trigger: "spec")
    expect(adapter).to have_received(:fetch_order_details).once
  end

  it "settles carts locally, without API calls, when regular polling already advanced the order" do
    order, cart = make_unpaid_order("58010000000000006")
    order.update!(status: "COMPLETED")

    result = described_class.call(credential, trigger: "spec")

    expect(result.success?).to eq(true)
    expect(cart.reload.status).to eq("converted")
    expect(cart.converted_order_id).to eq(order.id)
    expect(result.metadata).to include(settled_locally_count: 1)
  end
end
