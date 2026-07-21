require "rails_helper"
require "rake"

RSpec.describe "TikTok financial backfill rake tasks" do
  before(:all) do
    Rake::Task.define_task(:environment)
    load Rails.root.join("lib/tasks/tiktok.rake").to_s unless Rake::Task.task_defined?("tiktok:financial_backfill")
  end

  before do
    Rake::Task["tiktok:financial_backfill"].reenable
    Rake::Task["tiktok:financial_backfill_status"].reenable
  end

  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-#{SecureRandom.hex(4)}") }
  let(:credential) do
    tenant.channel_credentials.create!(
      channel: "tiktok",
      status: "active",
      credentials: { app_key: "key", app_secret: "secret", access_token: "token", shop_cipher: "cipher" }
    )
  end
  let(:job) { instance_double(ActiveJob::Base, job_id: "job-123") }

  def invoke_backfill(*arguments)
    Rake::Task["tiktok:financial_backfill"].invoke(*arguments)
  end

  it "requires max_orders" do
    expect { invoke_backfill("loja-teste") }.to raise_error(SystemExit)
  end

  it "passes max_orders 10 and defaults to safe batch settings" do
    expect(Integrations::Tiktok::FinancialBackfillJob).to receive(:perform_later).with(
      credential.id,
      batch_size: 50,
      batch_sleep: 0.5,
      force: false,
      max_orders: 10
    ).and_return(job)
    expect(Integrations::Tiktok::FinancialBackfillService).not_to receive(:call)

    expect {
      invoke_backfill(tenant.slug, "10")
    }.to output(
      a_string_including(
        "job_id=job-123",
        "tenant_slug=#{tenant.slug}",
        "max_orders=10",
        "batch_size=50",
        "batch_sleep=0.5",
        "force=false",
        "tiktok_financial_backfill_enqueued=true"
      )
    ).to_stdout
  end

  it "passes all as a nil max_orders and accepts explicit options" do
    expect(Integrations::Tiktok::FinancialBackfillJob).to receive(:perform_later).with(
      credential.id,
      batch_size: 25,
      batch_sleep: 0.5,
      force: false,
      max_orders: nil
    ).and_return(job)

    expect {
      invoke_backfill(tenant.slug, "all", "25", "0.5", "false")
    }.to output(a_string_including("max_orders=all", "batch_size=25")).to_stdout
  end

  it "accepts force true and enqueues only the job" do
    expect(Integrations::Tiktok::FinancialBackfillJob).to receive(:perform_later).with(
      credential.id,
      batch_size: 25,
      batch_sleep: 0,
      force: true,
      max_orders: 10
    ).and_return(job)
    expect(Integrations::Tiktok::FinancialBackfillService).not_to receive(:call)

    invoke_backfill(tenant.slug, "10", "25", "0", "true")
  end

  it "aborts invalid arguments" do
    invalid_arguments = [
      [ "0" ],
      [ "10", "0" ],
      [ "10", "50", "-0.1" ],
      [ "10", "50", "0.5", "maybe" ]
    ]

    invalid_arguments.each do |arguments|
      Rake::Task["tiktok:financial_backfill"].reenable
      expect { invoke_backfill("loja-teste", *arguments) }.to raise_error(SystemExit)
    end
  end

  it "prints the latest financial backfill status legibly" do
    IntegrationSyncLog.create!(
      tenant: tenant,
      direction: "inbound",
      action: Integrations::Tiktok::FinancialBackfillService::ACTION,
      status: "pending",
      started_at: Time.current,
      metadata: {
        "processed_count" => 3,
        "synced_count" => 2,
        "pending_statement_count" => 1,
        "error_count" => 0,
        "remaining_orders" => 4,
        "last_order_id" => 99,
        "max_orders" => 10
      }
    )

    expect {
      Rake::Task["tiktok:financial_backfill_status"].invoke(tenant.slug)
    }.to output(
      a_string_including(
        "status=pending",
        "processed_count=3",
        "synced_count=2",
        "pending_statement_count=1",
        "error_count=0",
        "remaining_orders=4",
        "last_order_id=99",
        "max_orders=10",
        "started_at=",
        "finished_at=nil"
      )
    ).to_stdout
  end
end
