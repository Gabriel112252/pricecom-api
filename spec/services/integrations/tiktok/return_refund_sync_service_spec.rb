require "rails_helper"

RSpec.describe Integrations::Tiktok::ReturnRefundSyncService do
  let(:tenant) { Tenant.create!(name: "Loja Returns", slug: "returns-#{SecureRandom.hex(4)}") }
  let(:channel) { Channel.ensure_for!(tenant, "tiktok") }
  let(:credential) do
    tenant.channel_credentials.create!(
      channel: "tiktok",
      status: "active",
      credentials: { app_key: "key", app_secret: "secret", access_token: "token", shop_cipher: "cipher" }
    )
  end
  let(:adapter) { instance_double(Integrations::TiktokAdapter) }

  before do
    allow(Integrations::TiktokAdapter).to receive(:new).and_return(adapter)
  end

  def return_order(order_id:, return_id: "ret-#{order_id}", return_status: "RETURN_OR_REFUND_REQUEST_SUCCESS", refund_total: "50.00")
    {
      "order_id" => order_id,
      "return_id" => return_id,
      "return_type" => "REFUND",
      "return_status" => return_status,
      "return_reason_text" => "Produto com defeito",
      "create_time" => 2.days.ago.to_i,
      "refund_amount" => { "currency" => "BRL", "refund_total" => refund_total }
    }
  end

  it "creates an OrderRefund with the real reason/status/amount from the Return and Refund API" do
    order = tenant.orders.create!(channel: channel, external_id: "order-1", order_number: "N-1", status: "DELIVERED")
    allow(adapter).to receive(:fetch_returns)
      .and_return({ "return_orders" => [ return_order(order_id: "order-1") ], "next_page_token" => nil })

    result = described_class.call(credential, trigger: "spec")

    expect(result.success?).to eq(true)
    refund = order.reload.order_refunds.sole
    expect(refund.amount).to eq(BigDecimal("50.00"))
    expect(refund.reason).to eq("Produto com defeito")
    expect(refund.status).to eq("processed")
    expect(refund.metadata["return_id"]).to eq("ret-order-1")
    expect(refund.metadata["return_type"]).to eq("REFUND")
    expect(order.refund_amount).to eq(BigDecimal("50.00"))
  end

  it "keeps status pending for an in-flight return, not yet resolved" do
    order = tenant.orders.create!(channel: channel, external_id: "order-1", order_number: "N-1", status: "DELIVERED")
    allow(adapter).to receive(:fetch_returns).and_return({
      "return_orders" => [ return_order(order_id: "order-1", return_status: "AWAITING_BUYER_SHIP") ],
      "next_page_token" => nil
    })

    described_class.call(credential, trigger: "spec")

    expect(order.reload.order_refunds.sole.status).to eq("pending")
  end

  it "does not error when the return references an order not found locally, and counts it as missing" do
    channel
    allow(adapter).to receive(:fetch_returns)
      .and_return({ "return_orders" => [ return_order(order_id: "order-ghost") ], "next_page_token" => nil })

    result = described_class.call(credential, trigger: "spec")

    expect(result.success?).to eq(true)
    expect(OrderRefund.count).to eq(0)
    log = tenant.integration_sync_logs.find_by!(action: "tiktok_return_refund_sync")
    expect(log.metadata["missing_count"]).to eq(1)
    expect(log.metadata["matched_count"]).to eq(0)
  end

  it "paginates through next_page_token until an empty page" do
    order_a = tenant.orders.create!(channel: channel, external_id: "order-a", order_number: "N-A", status: "DELIVERED")
    order_b = tenant.orders.create!(channel: channel, external_id: "order-b", order_number: "N-B", status: "DELIVERED")

    allow(adapter).to receive(:fetch_returns).with(hash_including(page_token: nil))
      .and_return({ "return_orders" => [ return_order(order_id: "order-a") ], "next_page_token" => "page-2" })
    allow(adapter).to receive(:fetch_returns).with(hash_including(page_token: "page-2"))
      .and_return({ "return_orders" => [ return_order(order_id: "order-b") ], "next_page_token" => nil })

    result = described_class.call(credential, trigger: "spec")

    expect(result.success?).to eq(true)
    expect(order_a.reload.order_refunds.count).to eq(1)
    expect(order_b.reload.order_refunds.count).to eq(1)
  end

  it "filters by order_ids instead of a time window when order_ids are given" do
    tenant.orders.create!(channel: channel, external_id: "order-1", order_number: "N-1", status: "DELIVERED")
    expect(adapter).to receive(:fetch_returns).with(
      filters: { order_ids: [ "order-1" ] }, page_size: described_class::PAGE_SIZE, page_token: nil
    ).and_return({ "return_orders" => [], "next_page_token" => nil })

    described_class.call(credential, order_ids: [ "order-1" ], trigger: "spec")
  end

  it "marks the credential as error and does not raise on an authentication failure" do
    channel
    allow(adapter).to receive(:fetch_returns).and_raise(Integrations::AuthenticationError, "token expirado")

    result = described_class.call(credential, trigger: "spec")

    expect(result.error?).to eq(true)
    expect(credential.reload.status).to eq("error")
  end

  it "re-raises RateLimitError so the job can back off and retry" do
    channel
    allow(adapter).to receive(:fetch_returns).and_raise(Integrations::RateLimitError.new("too many requests", retry_after: 5))

    expect { described_class.call(credential, trigger: "spec") }.to raise_error(Integrations::RateLimitError)

    log = tenant.integration_sync_logs.find_by!(action: "tiktok_return_refund_sync")
    expect(log.status).to eq("error")
  end

  it "skips when the tenant has no tiktok channel" do
    tenant_without_channel = Tenant.create!(name: "Sem Canal", slug: "sem-canal-#{SecureRandom.hex(4)}")
    credential_without_channel = tenant_without_channel.channel_credentials.create!(
      channel: "tiktok", status: "active",
      credentials: { app_key: "key", app_secret: "secret", access_token: "token", shop_cipher: "cipher" }
    )

    result = described_class.call(credential_without_channel, trigger: "spec")

    expect(result.skipped?).to eq(true)
  end
end
