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

  it "delegates to FinancialBackfillService with the credential and options" do
    expect(Integrations::Tiktok::FinancialBackfillService).to receive(:call).with(
      credential,
      batch_size: 10,
      batch_sleep: 0,
      force: true,
      max_orders: 10
    )

    described_class.new.perform(credential.id, batch_size: 10, batch_sleep: 0, force: true, max_orders: 10)
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
