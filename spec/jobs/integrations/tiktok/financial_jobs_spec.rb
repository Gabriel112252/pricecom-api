require "rails_helper"

RSpec.describe Integrations::Tiktok::FinancialBackfillJob do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-#{SecureRandom.hex(4)}") }
  let(:credential) do
    tenant.channel_credentials.create!(
      channel: "tiktok",
      status: "active",
      credentials: { app_key: "key", app_secret: "secret", access_token: "token", shop_cipher: "cipher" }
    )
  end

  before do
    allow(Integrations::Tiktok::FinancialBackfillService).to receive(:clear_due_continuation!).and_return(false)
  end

  def create_backfill_log(run_id:, force: false, max_orders: 1_000, metadata: {})
    IntegrationSyncLog.create!(
      tenant: credential.tenant,
      direction: "inbound",
      action: Integrations::Tiktok::FinancialBackfillService::ACTION,
      status: "pending",
      started_at: Time.current,
      metadata: {
        "channel_credential_id" => credential.id,
        "force" => force,
        "run_id" => run_id,
        "processed_count" => 110,
        "run_started_processed_count" => 110,
        "run_processed_count" => 182,
        "run_target_count" => max_orders,
        "max_orders" => max_orders,
        "last_order_id" => 182,
        "continuation_count" => 0,
        "rate_limit_count" => 1
      }.merge(metadata)
    )
  end

  it "delegates to FinancialBackfillService with the credential and options" do
    job = described_class.new(credential.id)
    expect(Integrations::Tiktok::FinancialBackfillService).to receive(:call).with(
      credential,
      batch_size: 10,
      batch_sleep: 0,
      force: true,
      max_orders: 10,
      run_id: job.job_id
    )

    job.perform(credential.id, batch_size: 10, batch_sleep: 0, force: true, max_orders: 10)
  end

  it "schedules one rate-limit continuation with the same run and options" do
    job = described_class.new(
      credential.id,
      batch_size: 10,
      batch_sleep: 0.25,
      force: true,
      max_orders: 1_000
    )
    log = create_backfill_log(run_id: job.job_id, force: true)
    error = Integrations::RateLimitError.new("too many requests", retry_after: 90)
    continuation = instance_double(ActiveJob::ConfiguredJob)

    allow(Integrations::Tiktok::FinancialBackfillService).to receive(:clear_due_continuation!).and_call_original
    allow(Integrations::Tiktok::FinancialBackfillService).to receive(:call).and_raise(error)
    allow(described_class).to receive(:set).with(wait: 90.seconds).and_return(continuation)
    expect(continuation).to receive(:perform_later).with(
      credential.id,
      batch_size: 10,
      batch_sleep: 0.25,
      force: true,
      max_orders: 1_000,
      run_id: job.job_id
    )

    expect { job.perform_now }.not_to raise_error

    metadata = log.reload.metadata
    expect(metadata["continuation_scheduled_at"]).to be_present
    expect(metadata["continuation_run_at"]).to be_present
    expect(metadata["continuation_count"]).to eq(1)
    expect(metadata["rate_limit_count"]).to eq(1)
    expect(metadata["run_id"]).to eq(job.job_id)
    expect(metadata["run_processed_count"]).to eq(182)
    expect(metadata["max_orders"]).to eq(1_000)
  end

  it "uses a two-minute fallback and clamps rate-limit waits" do
    job = described_class.new(credential.id)

    expect(job.send(:rate_limit_wait_seconds, Integrations::RateLimitError.new)).to eq(2.minutes.to_i)
    expect(job.send(:rate_limit_wait_seconds, Integrations::RateLimitError.new("short", retry_after: 5)))
      .to eq(1.minute.to_i)
    expect(job.send(:rate_limit_wait_seconds, Integrations::RateLimitError.new("long", retry_after: 31.minutes.to_i)))
      .to eq(30.minutes.to_i)
  end

  it "does not schedule a duplicate future continuation for the same run" do
    job = described_class.new(credential.id, batch_size: 10, max_orders: 1_000)
    log = create_backfill_log(run_id: job.job_id)
    error = Integrations::RateLimitError.new("too many requests", retry_after: 90)
    continuation = instance_double(ActiveJob::ConfiguredJob)

    allow(Integrations::Tiktok::FinancialBackfillService).to receive(:clear_due_continuation!).and_call_original
    allow(Integrations::Tiktok::FinancialBackfillService).to receive(:call).and_raise(error)
    allow(described_class).to receive(:set).with(wait: 90.seconds).and_return(continuation)
    expect(continuation).to receive(:perform_later).once

    expect { job.perform_now }.not_to raise_error
    expect { job.perform_now }.not_to raise_error

    expect(described_class).to have_received(:set).once
    expect(log.reload.metadata["continuation_count"]).to eq(1)
  end

  it "clears a due continuation before resuming and does not schedule after completion" do
    job = described_class.new(credential.id, max_orders: 1_000)
    log = create_backfill_log(
      run_id: job.job_id,
      metadata: {
        "continuation_scheduled_at" => 1.minute.ago,
        "continuation_run_at" => 1.second.ago
      }
    )
    result = Integrations::Tiktok::FinancialBackfillService::Result.new(outcome: :success)

    allow(Integrations::Tiktok::FinancialBackfillService).to receive(:clear_due_continuation!).and_call_original
    allow(Integrations::Tiktok::FinancialBackfillService).to receive(:call).and_return(result)
    expect(described_class).not_to receive(:set)

    expect { job.perform_now }.not_to raise_error

    expect(log.reload.metadata).not_to have_key("continuation_scheduled_at")
    expect(log.reload.metadata).not_to have_key("continuation_run_at")
  end

  it "does not enter a continuation loop for authentication errors" do
    job = described_class.new(credential.id, max_orders: 1_000)
    create_backfill_log(run_id: job.job_id)
    result = Integrations::Tiktok::FinancialBackfillService::Result.new(outcome: :error)

    allow(Integrations::Tiktok::FinancialBackfillService).to receive(:call).and_return(result)
    expect(described_class).not_to receive(:set)

    expect { job.perform_now }.not_to raise_error
  end

  it "retries LockLostError after one minute" do
    credential_id = 999
    job = described_class.new(credential_id)
    credential_stub = instance_double(ChannelCredential)
    error = Integrations::Tiktok::FinancialSyncLock::LockLostError.new("lock perdido")
    allow(ChannelCredential).to receive(:find_by).with(id: credential_id).and_return(credential_stub)
    allow(Integrations::Tiktok::FinancialBackfillService).to receive(:call).and_raise(error)
    allow(job).to receive(:retry_job)

    expect { job.perform_now }.not_to raise_error
    expect(job).to have_received(:retry_job).with(hash_including(wait: 1.minute, error: error))
  end

  it "retries LockBusyError after two minutes" do
    credential_id = 998
    job = described_class.new(credential_id)
    credential_stub = instance_double(ChannelCredential)
    error = Integrations::Tiktok::FinancialSyncLock::LockBusyError.new("lock ocupado")
    allow(ChannelCredential).to receive(:find_by).with(id: credential_id).and_return(credential_stub)
    allow(Integrations::Tiktok::FinancialBackfillService).to receive(:call).and_raise(error)
    allow(job).to receive(:retry_job)

    expect { job.perform_now }.not_to raise_error
    expect(job).to have_received(:retry_job).with(hash_including(wait: 2.minutes, error: error))
  end

  it "finishes normally when the service returns pending" do
    job = described_class.new(997)
    credential_stub = instance_double(ChannelCredential)
    pending_result = Integrations::Tiktok::FinancialBackfillService::Result.new(outcome: :pending)
    allow(ChannelCredential).to receive(:find_by).with(id: 997).and_return(credential_stub)
    allow(Integrations::Tiktok::FinancialBackfillService).to receive(:call).and_return(pending_result)
    allow(job).to receive(:retry_job)

    expect { job.perform_now }.not_to raise_error
    expect(job).not_to have_received(:retry_job)
  end

  it "does nothing without raising when the credential no longer exists" do
    allow(ChannelCredential).to receive(:find_by).with(id: 996).and_return(nil)
    expect(Integrations::Tiktok::FinancialBackfillService).not_to receive(:call)

    expect { described_class.new.perform(996) }.not_to raise_error
  end

  it "does nothing when the credential no longer exists" do
    expect(Integrations::Tiktok::FinancialBackfillService).not_to receive(:call)

    described_class.new.perform(-1)
  end
end

RSpec.describe Integrations::Tiktok::PendingFinancialSyncJob do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-#{SecureRandom.hex(4)}") }
  let(:credential) do
    tenant.channel_credentials.create!(
      channel: "tiktok",
      status: "active",
      credentials: { app_key: "key", app_secret: "secret", access_token: "token", shop_cipher: "cipher" }
    )
  end

  it "delegates to the shared non-force financial service" do
    expect(Integrations::Tiktok::FinancialBackfillService).to receive(:call).with(
      credential,
      batch_size: 25,
      batch_sleep: 0,
      force: false
    )

    described_class.new.perform(credential.id, batch_size: 25, batch_sleep: 0)
  end

  it "does nothing when the credential no longer exists" do
    expect(Integrations::Tiktok::FinancialBackfillService).not_to receive(:call)

    described_class.new.perform(-1)
  end
end
