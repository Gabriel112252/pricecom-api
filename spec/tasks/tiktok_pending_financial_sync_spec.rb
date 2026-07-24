require "rails_helper"
require "rake"

RSpec.describe "tiktok:pending_financial_sync rake task" do
  before(:all) do
    Rake::Task.define_task(:environment)
    load Rails.root.join("lib/tasks/tiktok.rake").to_s unless Rake::Task.task_defined?("tiktok:pending_financial_sync")
  end

  before { Rake::Task["tiktok:pending_financial_sync"].reenable }

  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-#{SecureRandom.hex(4)}") }
  let!(:credential) do
    tenant.channel_credentials.create!(
      channel: "tiktok",
      status: "active",
      credentials: { app_key: "key", app_secret: "secret", access_token: "token", shop_cipher: "cipher" }
    )
  end

  def invoke(*arguments)
    Rake::Task["tiktok:pending_financial_sync"].invoke(*arguments)
  end

  def success_result(metadata = {})
    Integrations::Tiktok::PendingFinancialSyncService::Result.new(
      outcome: :success,
      error_message: nil,
      metadata: { "processed_count" => 3, "synced_count" => 2, "pending_count" => 1, "error_count" => 0 }.merge(metadata)
    )
  end

  it "runs one synchronous round with the scheduler's small batch by default" do
    expect(Integrations::Tiktok::PendingFinancialSyncService).to receive(:call).with(
      credential,
      batch_size: Integrations::Tiktok::PendingFinancialSyncSchedulerJob::SCHEDULED_BATCH_SIZE,
      window_days: Integrations::Tiktok::PendingFinancialSyncService::DEFAULT_WINDOW_DAYS
    ).and_return(success_result)

    expect { invoke(tenant.slug) }.to output(/outcome=success/).to_stdout
  end

  it "honours explicit batch_size and window_days" do
    expect(Integrations::Tiktok::PendingFinancialSyncService).to receive(:call).with(
      credential,
      batch_size: 10,
      window_days: 30
    ).and_return(success_result)

    expect { invoke(tenant.slug, "10", "30") }.to output(/batch_size=10/).to_stdout
  end

  it "aborts with a clear message when the lock is busy" do
    allow(Integrations::Tiktok::PendingFinancialSyncService).to receive(:call)
      .and_raise(Integrations::Tiktok::FinancialSyncLock::LockBusyError)

    expect { invoke(tenant.slug) }.to raise_error(SystemExit)
      .and output(/lock ocupado/).to_stderr
  end

  it "aborts on invalid batch_size without calling the service" do
    expect(Integrations::Tiktok::PendingFinancialSyncService).not_to receive(:call)

    expect { invoke(tenant.slug, "zero") }.to raise_error(SystemExit)
  end

  it "aborts when the tenant has no active TikTok credential" do
    credential.update!(status: "error")
    expect(Integrations::Tiktok::PendingFinancialSyncService).not_to receive(:call)

    expect { invoke(tenant.slug) }.to raise_error(SystemExit)
  end

  it "exits non-zero when the round finishes with errors" do
    allow(Integrations::Tiktok::PendingFinancialSyncService).to receive(:call).and_return(
      Integrations::Tiktok::PendingFinancialSyncService::Result.new(
        outcome: :error,
        error_message: "boom",
        metadata: { "error_count" => 1 }
      )
    )

    expect { invoke(tenant.slug) }.to raise_error(SystemExit)
      .and output(/outcome=error/).to_stdout
  end
end
