require "rails_helper"

RSpec.describe Integrations::Tiktok::PendingFinancialSyncService do
  let(:tenant) { Tenant.create!(name: "Loja Pending", slug: "pending-#{SecureRandom.hex(4)}") }
  let(:channel) { Channel.ensure_for!(tenant, "tiktok") }
  let(:credential) do
    tenant.channel_credentials.create!(
      channel: "tiktok",
      status: "active",
      credentials: { app_key: "key", app_secret: "secret", access_token: "token", shop_cipher: "cipher" }
    )
  end
  let(:adapter) { instance_double(Integrations::TiktokAdapter) }
  let(:lock) { instance_double(Integrations::Tiktok::FinancialSyncLock, acquire: true, release: true) }

  before do
    allow(Integrations::TiktokAdapter).to receive(:new).and_return(adapter)
    allow(Integrations::Tiktok::FinancialSyncLock).to receive(:new).and_return(lock)
    # Nenhum teste deste arquivo depende do delay real entre pedidos —
    # sem isso, specs com mais de um pedido pausariam de verdade por
    # PENDING_SYNC_SLEEP_SECONDS a cada execução.
    allow_any_instance_of(described_class).to receive(:sleep)
  end

  it "keeps an order pending when the statement is not available" do
    order = tenant.orders.create!(channel: channel, external_id: "order-1", status: "COMPLETED", ordered_at: 1.day.ago)
    allow(Integrations::Tiktok::OrderFinancialSyncService).to receive(:call)
      .and_raise(Integrations::Tiktok::OrderFinancialSyncService::PendingStatementError, "not settled")

    result = described_class.call(credential, order_ids: [ order.id ], batch_size: 1)

    expect(result.success?).to eq(true)
    expect(result.metadata["pending_count"]).to eq(1)
    expect(order.reload.financial_synced_at).to be_nil
  end

  it "stops consulting an order after a later successful sync" do
    order = tenant.orders.create!(channel: channel, external_id: "order-1", status: "COMPLETED", ordered_at: 1.day.ago)
    allow(Integrations::Tiktok::OrderFinancialSyncService).to receive(:call) do |order:, **|
      order.update!(financial_synced_at: Time.current)
      order
    end

    described_class.call(credential, order_ids: [ order.id ], batch_size: 1)
    described_class.call(credential, order_ids: [ order.id ], batch_size: 1)

    expect(Integrations::Tiktok::OrderFinancialSyncService).to have_received(:call).once
  end

  it "does not exclude an otherwise-eligible order because a stale 'pending' log points a cursor past its id" do
    order = tenant.orders.create!(channel: channel, external_id: "order-1", status: "COMPLETED", ordered_at: 1.day.ago)

    # Simulates a previous run that was interrupted by a rate limit on some
    # later order — the log stayed "pending" with a last_order_id far above
    # the id of the order created (and reset-to-eligible) afterwards.
    IntegrationSyncLog.create!(
      tenant: tenant,
      direction: "inbound",
      action: described_class::ACTION,
      status: "pending",
      started_at: 1.hour.ago,
      error_message: "rate limited",
      metadata: { "channel_credential_id" => credential.id, "last_order_id" => order.id + 1_000_000 }
    )

    allow(Integrations::Tiktok::OrderFinancialSyncService).to receive(:call) do |order:, **|
      order.update!(financial_synced_at: Time.current)
      order
    end

    result = described_class.call(credential, batch_size: 1)

    expect(Integrations::Tiktok::OrderFinancialSyncService).to have_received(:call).once
    expect(result.metadata["synced_count"]).to eq(1)
    expect(order.reload.financial_synced_at).to be_present
  end

  it "stops the batch on a rate limit without raising, and reschedules only the affected order" do
    order1 = tenant.orders.create!(channel: channel, external_id: "order-1", status: "COMPLETED", ordered_at: 1.day.ago)
    order2 = tenant.orders.create!(channel: channel, external_id: "order-2", status: "COMPLETED", ordered_at: 1.day.ago)
    allow(Integrations::Tiktok::OrderFinancialSyncService).to receive(:call)
      .and_raise(Integrations::RateLimitError.new("rate limited", retry_after: 30))

    result = described_class.call(credential, order_ids: [ order1.id, order2.id ], batch_size: 10)

    expect(result.success?).to eq(true)
    expect(result.metadata["pending_count"]).to eq(1)
    expect(Integrations::Tiktok::OrderFinancialSyncService).to have_received(:call).once
    expect(order1.reload.financial_pending_reason).to eq("rate_limited")
    expect(order1.financial_next_attempt_at).to be_present
    expect(order2.reload.financial_pending_reason).to be_nil
  end

  it "throttles between successful orders to avoid tripping the Finance API rate limit" do
    order1 = tenant.orders.create!(channel: channel, external_id: "order-1", status: "COMPLETED", ordered_at: 1.day.ago)
    order2 = tenant.orders.create!(channel: channel, external_id: "order-2", status: "COMPLETED", ordered_at: 1.day.ago)
    allow(Integrations::Tiktok::OrderFinancialSyncService).to receive(:call) do |order:, **|
      order.update!(financial_synced_at: Time.current)
      order
    end
    expect_any_instance_of(described_class).to receive(:sleep).with(described_class::PENDING_SYNC_SLEEP_SECONDS).once

    described_class.call(credential, order_ids: [ order1.id, order2.id ], batch_size: 2)
  end
end
