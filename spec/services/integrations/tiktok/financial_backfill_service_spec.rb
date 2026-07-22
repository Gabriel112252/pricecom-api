require "rails_helper"

RSpec.describe Integrations::Tiktok::FinancialBackfillService do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-#{SecureRandom.hex(4)}") }
  let(:channel) { Channel.ensure_for!(tenant, "tiktok") }
  let(:channel_credential) do
    tenant.channel_credentials.create!(
      channel: "tiktok",
      status: "active",
      credentials: { app_key: "key", app_secret: "secret", access_token: "token", shop_cipher: "cipher" }
    )
  end
  let(:adapter) { instance_double(Integrations::TiktokAdapter) }
  let(:lock) { instance_double(Integrations::Tiktok::FinancialSyncLock, acquire: true, renew: true, release: true) }

  before do
    channel
    channel_credential
    allow(Integrations::TiktokAdapter).to receive(:new).and_return(adapter)
    allow(Integrations::Tiktok::FinancialSyncLock).to receive(:new).and_return(lock)
    allow(Integrations::Tiktok::OrderFinancialSyncService).to receive(:call) do |order:, **|
      # Model the real sync service's source-of-truth update for scope tests.
      order.update!(financial_synced_at: Time.current)
      order
    end
  end

  def make_order(status: "COMPLETED", synced: false, channel: self.channel, external_id: SecureRandom.uuid)
    channel.orders.create!(
      external_id: external_id,
      order_number: external_id,
      status: status,
      order_type: "sale",
      gross_value: 100,
      freight: 0,
      discount: 0,
      financial_synced_at: synced ? Time.current : nil
    )
  end

  def run_backfill(force: false, batch_size: 50, max_orders: nil, run_id: nil)
    described_class.call(
      channel_credential,
      batch_size: batch_size,
      batch_sleep: 0,
      force: force,
      max_orders: max_orders,
      run_id: run_id
    )
  end

  def latest_log
    IntegrationSyncLog.where(tenant: tenant, action: described_class::ACTION).order(created_at: :desc).first
  end

  def create_pending_log(metadata)
    IntegrationSyncLog.create!(
      tenant: tenant,
      direction: "inbound",
      action: described_class::ACTION,
      status: "pending",
      started_at: 1.minute.ago,
      metadata: metadata
    )
  end

  it "processes only orders from the tenant's TikTok channel" do
    tiktok_order = make_order
    yampi_channel = tenant.channels.create!(name: "Yampi", platform: "yampi")
    yampi_order = make_order(channel: yampi_channel, external_id: "yampi-1")

    result = run_backfill

    expect(result.success?).to eq(true)
    expect(Integrations::Tiktok::OrderFinancialSyncService).to have_received(:call).with(
      hash_including(order: tiktok_order, channel_credential: channel_credential, adapter: adapter)
    ).once
    expect(Integrations::Tiktok::OrderFinancialSyncService).not_to have_received(:call).with(
      hash_including(order: yampi_order)
    )
  end

  it "skips already synchronized orders unless force is enabled" do
    make_order(synced: true)

    result = run_backfill

    expect(result.metadata["eligible_orders"]).to eq(0)
    expect(result.metadata["skipped_count"]).to eq(1)
    expect(Integrations::Tiktok::OrderFinancialSyncService).not_to have_received(:call)
    expect(latest_log.status).to eq("success")
  end

  it "uses batches independently from the total max_orders limit" do
    25.times { make_order }

    result = run_backfill(batch_size: 10)

    expect(Integrations::Tiktok::OrderFinancialSyncService).to have_received(:call).exactly(25).times
    expect(lock).to have_received(:renew).at_least(3).times
    expect(result.metadata["max_orders"]).to be_nil
  end

  it "continues normally when every lock renewal succeeds" do
    order = make_order

    result = run_backfill

    expect(result.success?).to eq(true)
    expect(Integrations::Tiktok::OrderFinancialSyncService).to have_received(:call).with(
      hash_including(order: order)
    ).once
    expect(lock).to have_received(:renew).at_least(2).times
  end

  it "raises LockBusyError without creating or changing a checkpoint" do
    make_order
    allow(lock).to receive(:acquire).and_return(false)

    expect { run_backfill }.to raise_error(
      Integrations::Tiktok::FinancialSyncLock::LockBusyError,
      "backfill financeiro TikTok já está em execução"
    )

    expect(IntegrationSyncLog.where(tenant: tenant, action: described_class::ACTION)).to be_empty
    expect(lock).not_to have_received(:release)
    expect(Integrations::Tiktok::OrderFinancialSyncService).not_to have_received(:call)
  end

  it "raises immediately when the lock is lost before a batch" do
    make_order
    allow(lock).to receive(:renew).and_return(false)

    expect { run_backfill }.to raise_error(
      Integrations::Tiktok::FinancialSyncLock::LockLostError,
      "lock do backfill financeiro TikTok foi perdido"
    )

    expect(Integrations::Tiktok::OrderFinancialSyncService).not_to have_received(:call)
    expect(latest_log.status).to eq("error")
    expect(latest_log.status).not_to eq("success")
  end

  it "preserves the last completed checkpoint and does not process the next batch" do
    first = make_order(external_id: "1")
    second = make_order(external_id: "2")
    allow(lock).to receive(:renew).and_return(true, true, false)

    expect { run_backfill(batch_size: 1) }.to raise_error(
      Integrations::Tiktok::FinancialSyncLock::LockLostError
    )

    expect(latest_log.status).to eq("error")
    expect(latest_log.metadata["last_order_id"]).to eq(first.id)
    expect(Integrations::Tiktok::OrderFinancialSyncService).to have_received(:call).with(
      hash_including(order: first)
    ).once
    expect(Integrations::Tiktok::OrderFinancialSyncService).not_to have_received(:call).with(
      hash_including(order: second)
    )
  end

  it "renews during a batch with more than ten orders" do
    25.times { make_order }

    run_backfill(batch_size: 50)

    # Before the batch, after order 10, after order 20 and after checkpoint.
    expect(lock).to have_received(:renew).exactly(4).times
  end

  it "limits a pilot execution to max_orders 10" do
    25.times { make_order }

    result = run_backfill(batch_size: 3, max_orders: 10)

    expect(Integrations::Tiktok::OrderFinancialSyncService).to have_received(:call).exactly(10).times
    expect(result.metadata["max_orders"]).to eq(10)
    expect(result.metadata["remaining_orders"]).to eq(15)
    expect(result.pending?).to eq(true)
  end

  it "limits a pilot execution to max_orders 100" do
    120.times { make_order }

    result = run_backfill(batch_size: 10, max_orders: 100)

    expect(Integrations::Tiktok::OrderFinancialSyncService).to have_received(:call).exactly(100).times
    expect(result.metadata["max_orders"]).to eq(100)
    expect(result.metadata["remaining_orders"]).to eq(20)
    expect(result.pending?).to eq(true)
  end

  it "limits max_orders 1000 across the complete operation" do
    1_100.times { make_order }

    result = run_backfill(batch_size: 100, max_orders: 1_000, run_id: "run-1000")
    metadata = latest_log.metadata

    expect(Integrations::Tiktok::OrderFinancialSyncService).to have_received(:call).exactly(1_000).times
    expect(result.pending?).to eq(true)
    expect(metadata).to include(
      "run_id" => "run-1000",
      "run_started_processed_count" => 0,
      "run_processed_count" => 1_000,
      "run_target_count" => 1_000,
      "max_orders" => 1_000
    )
  end

  it "counts processed orders before a rate limit and only processes the remaining capacity on retry" do
    orders = 1_200.times.map { make_order }
    rate_limited = true
    allow(Integrations::Tiktok::OrderFinancialSyncService).to receive(:call) do |order:, **|
      if order == orders[182] && rate_limited
        rate_limited = false
        raise Integrations::RateLimitError.new("too many requests", retry_after: 1)
      end

      order.update!(financial_synced_at: Time.current)
      order
    end

    expect { run_backfill(batch_size: 1_000, max_orders: 1_000, run_id: "run-rate-limit") }
      .to raise_error(Integrations::RateLimitError)

    first_metadata = latest_log.metadata
    expect(first_metadata).to include(
      "run_id" => "run-rate-limit",
      "run_started_processed_count" => 0,
      "run_processed_count" => 182,
      "run_target_count" => 1_000
    )
    expect(first_metadata["last_order_id"]).to eq(orders[181].id)

    result = run_backfill(batch_size: 1_000, max_orders: 1_000, run_id: "run-rate-limit")
    metadata = latest_log.metadata

    expect(result.pending?).to eq(true)
    expect(metadata["run_processed_count"]).to eq(1_000)
    expect(metadata["processed_count"]).to eq(1_000)
    expect(Integrations::Tiktok::OrderFinancialSyncService).not_to have_received(:call).with(
      hash_including(order: orders[1_000])
    )
  end

  it "does not call TikTok after a run reaches its max_orders capacity" do
    orders = 1_100.times.map { make_order }
    run_id = "run-capacity"

    run_backfill(batch_size: 100, max_orders: 1_000, run_id: run_id)
    result = run_backfill(batch_size: 100, max_orders: 1_000, run_id: run_id)

    expect(result.pending?).to eq(true)
    expect(Integrations::Tiktok::OrderFinancialSyncService).to have_received(:call).exactly(1_000).times
    expect(Integrations::Tiktok::OrderFinancialSyncService).not_to have_received(:call).with(
      hash_including(order: orders[1_000])
    )
    expect(orders[1_000].reload.financial_synced_at).to be_nil
  end

  it "starts a new batch with a new run_id while keeping the global processed count" do
    orders = 2_000.times.map { make_order }

    first_result = run_backfill(batch_size: 100, max_orders: 1_000, run_id: "run-first")
    second_result = run_backfill(batch_size: 100, max_orders: 1_000, run_id: "run-second")
    metadata = latest_log.metadata

    expect(first_result.pending?).to eq(true)
    expect(second_result.success?).to eq(true)
    expect(metadata).to include(
      "run_id" => "run-second",
      "run_started_processed_count" => 1_000,
      "run_processed_count" => 1_000,
      "run_target_count" => 1_000,
      "processed_count" => 2_000
    )
    expect(Integrations::Tiktok::OrderFinancialSyncService).to have_received(:call).exactly(2_000).times
    expect(orders.map { |order| order.reload.financial_synced_at }.compact.size).to eq(2_000)
  end

  it "resets run_processed_count only when run_id changes" do
    3.times { make_order }

    run_backfill(batch_size: 1, max_orders: 2, run_id: "run-one")
    same_run_result = run_backfill(batch_size: 1, max_orders: 2, run_id: "run-one")
    same_run_metadata = latest_log.metadata

    expect(same_run_result.pending?).to eq(true)
    expect(same_run_metadata["run_processed_count"]).to eq(2)

    run_backfill(batch_size: 1, max_orders: 1, run_id: "run-two")
    new_run_metadata = latest_log.metadata

    expect(new_run_metadata["run_started_processed_count"]).to eq(2)
    expect(new_run_metadata["run_processed_count"]).to eq(1)
    expect(new_run_metadata["processed_count"]).to eq(3)
  end

  it "does not inherit a max_orders limit from a legacy log without run_id" do
    first = make_order(synced: true)
    second = make_order
    third = make_order
    create_pending_log(
      "channel_credential_id" => channel_credential.id,
      "force" => false,
      "processed_count" => 1,
      "last_order_id" => first.id,
      "max_orders" => 1
    )

    result = run_backfill(batch_size: 1, max_orders: 2, run_id: "run-new")
    metadata = latest_log.metadata

    expect(result.success?).to eq(true)
    expect(metadata).to include(
      "run_id" => "run-new",
      "run_started_processed_count" => 1,
      "run_processed_count" => 2,
      "run_target_count" => 2,
      "processed_count" => 3
    )
    expect(Integrations::Tiktok::OrderFinancialSyncService).to have_received(:call).with(
      hash_including(order: second)
    ).once
    expect(Integrations::Tiktok::OrderFinancialSyncService).to have_received(:call).with(
      hash_including(order: third)
    ).once
  end

  it "reprocesses old synchronized orders with force and excludes successes during the same run" do
    old_order = make_order(synced: true)
    old_order.update!(financial_synced_at: 1.hour.ago)
    new_order = make_order

    result = run_backfill(force: true)
    metadata = latest_log.metadata

    expect(result.success?).to eq(true)
    expect(metadata["run_started_at"]).to be_present
    expect(Integrations::Tiktok::OrderFinancialSyncService).to have_received(:call).with(
      hash_including(order: old_order)
    ).once
    expect(Integrations::Tiktok::OrderFinancialSyncService).to have_received(:call).with(
      hash_including(order: new_order)
    ).once
  end

  it "persists a checkpoint after each batch" do
    first = make_order(external_id: "1")
    second = make_order(external_id: "2")

    result = run_backfill(batch_size: 1)
    metadata = latest_log.metadata

    expect(result.metadata["processed_count"]).to eq(2)
    expect(metadata["total_orders"]).to eq(2)
    expect(metadata["eligible_orders"]).to eq(2)
    expect(metadata["remaining_orders"]).to eq(0)
    expect(metadata["synced_count"]).to eq(2)
    expect(metadata["last_order_id"]).to eq(second.id)
    expect(metadata["last_batch_at"]).to be_present
    expect(metadata).to include(
      "run_started_at", "pass_count", "max_orders", "pending_samples", "error_samples"
    )
    expect(first.id).to be < second.id
  end

  it "never decreases the monotonic checkpoint across resumptions" do
    first = make_order(external_id: "1")
    second = make_order(external_id: "2")

    run_backfill(max_orders: 1)
    first_checkpoint = latest_log.metadata["last_order_id"]

    run_backfill(max_orders: 1)
    final_checkpoint = latest_log.metadata["last_order_id"]

    expect(first_checkpoint).to eq(first.id)
    expect(final_checkpoint).to eq(second.id)
    expect(final_checkpoint).to be > first_checkpoint
  end

  it "resumes after a rate-limit interruption from the saved last_order_id" do
    first = make_order(external_id: "1")
    second = make_order(external_id: "2")
    first_run = true

    allow(Integrations::Tiktok::OrderFinancialSyncService).to receive(:call) do |order:, **|
      raise Integrations::RateLimitError.new("too many requests", retry_after: 1) if order == second && first_run

      order.update!(financial_synced_at: Time.current)
      order
    end

    expect { run_backfill(batch_size: 1) }.to raise_error(Integrations::RateLimitError)
    expect(latest_log.status).to eq("pending")
    expect(latest_log.metadata["last_order_id"]).to eq(first.id)

    first_run = false
    result = run_backfill(batch_size: 1)

    expect(result.success?).to eq(true)
    expect(Integrations::Tiktok::OrderFinancialSyncService).to have_received(:call).with(
      hash_including(order: first)
    ).once
    expect(Integrations::Tiktok::OrderFinancialSyncService).to have_received(:call).with(
      hash_including(order: second)
    ).twice
  end

  it "does not persist pending order IDs or build SQL from pending ID lists" do
    order = make_order
    allow(Integrations::Tiktok::OrderFinancialSyncService).to receive(:call)
      .and_raise(Integrations::Tiktok::OrderFinancialSyncService::PendingStatementError, "statement unavailable")

    sql = []
    subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _started, _finished, _id, payload|
      sql << payload[:sql]
    end
    run_backfill
    ActiveSupport::Notifications.unsubscribe(subscription)

    expect(latest_log.metadata).not_to have_key("pending_order_ids")
    expect(sql).not_to include(a_string_matching(/"orders"\."id"\s+IN/i))
    expect(order.reload.financial_synced_at).to be_nil
  end

  it "records an unavailable statement as pending and starts a new pass next time" do
    order = make_order
    allow(Integrations::Tiktok::OrderFinancialSyncService).to receive(:call)
      .and_raise(Integrations::Tiktok::OrderFinancialSyncService::PendingStatementError, "statement unavailable")

    result = run_backfill
    first_metadata = latest_log.metadata

    expect(result.pending?).to eq(true)
    expect(latest_log.status).to eq("pending")
    expect(first_metadata["pending_statement_count"]).to eq(1)
    expect(first_metadata["pending_samples"]).to include(a_string_including("#{order.id}"))
    expect(first_metadata["pass_count"]).to eq(1)
    expect(first_metadata["last_order_id"]).to be_nil
    expect(first_metadata).not_to have_key("pending_order_ids")
  end

  it "resets pending samples for the next pass and clears them when resolved" do
    order = make_order
    run_id = "run-pending-pass"
    allow(Integrations::Tiktok::OrderFinancialSyncService).to receive(:call)
      .and_raise(Integrations::Tiktok::OrderFinancialSyncService::PendingStatementError, "statement unavailable")

    run_backfill(run_id: run_id)

    allow(Integrations::Tiktok::OrderFinancialSyncService).to receive(:call) do |order:, **|
      order.update!(financial_synced_at: Time.current)
      order
    end
    result = run_backfill(run_id: run_id)

    expect(result.success?).to eq(true)
    expect(result.metadata["pending_statement_count"]).to eq(0)
    expect(result.metadata["pending_samples"]).to eq([])
    expect(result.metadata["pass_count"]).to eq(1)
  end

  it "continues after an error on one order and records an error sample" do
    first = make_order(external_id: "1")
    second = make_order(external_id: "2")
    allow(Integrations::Tiktok::OrderFinancialSyncService).to receive(:call) do |order:, **|
      raise Integrations::ApiError, "malformed statement" if order == first

      order.update!(financial_synced_at: Time.current)
      order
    end

    result = run_backfill

    expect(result.error?).to eq(true)
    expect(latest_log.metadata["error_count"]).to eq(1)
    expect(latest_log.metadata["synced_count"]).to eq(1)
    expect(latest_log.metadata["error_samples"]).to include(a_string_including("#{first.id}"))
    expect(Integrations::Tiktok::OrderFinancialSyncService).to have_received(:call).with(
      hash_including(order: second)
    ).once
  end

  it "does not resume a pending log from another credential" do
    make_order
    create_pending_log("channel_credential_id" => channel_credential.id + 1, "force" => false)

    run_backfill

    expect(IntegrationSyncLog.where(tenant: tenant, action: described_class::ACTION).count).to eq(2)
    expect(latest_log.status).to eq("success")
  end

  it "does not resume a pending log with a different force mode" do
    make_order
    create_pending_log("channel_credential_id" => channel_credential.id, "force" => true)

    run_backfill(force: false)

    expect(IntegrationSyncLog.where(tenant: tenant, action: described_class::ACTION).count).to eq(2)
    expect(latest_log.metadata["force"]).to eq(false)
    expect(latest_log.status).to eq("success")
  end

  it "classifies explicit statement-unavailable errors but not statement ready" do
    service = described_class.allocate

    expect(service.send(:pending_statement_error?, Integrations::ApiError.new("statement not ready"))).to eq(true)
    expect(service.send(:pending_statement_error?, Integrations::ApiError.new("statement ready"))).to eq(false)
    expect(service.send(:pending_statement_error?, Integrations::ApiError.new("settlement pending"))).to eq(true)
    expect(service.send(:pending_statement_error?, Integrations::ApiError.new("statement not found"))).to eq(true)
  end

  it "does not duplicate financial updates on a second non-force execution" do
    order = make_order

    run_backfill
    run_backfill

    expect(Integrations::Tiktok::OrderFinancialSyncService).to have_received(:call).with(
      hash_including(order: order)
    ).once
  end

  it "does not delete an order or its items" do
    order = make_order
    item = order.order_items.create!(sku: "SKU-1", name: "Produto", quantity: 1, unit_cost: 10)

    run_backfill

    expect(Order.find(order.id)).to be_present
    expect(order.order_items.where(id: item.id)).to exist
  end
end
