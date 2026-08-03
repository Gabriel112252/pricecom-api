require "rails_helper"

RSpec.describe Integrations::Tiktok::PendingFinancialSyncJob do
  let(:tenant) { Tenant.create!(name: "Loja Job", slug: "loja-job-#{SecureRandom.hex(4)}") }
  let(:credential) do
    tenant.channel_credentials.create!(
      channel: "tiktok",
      status: "active",
      credentials: { app_key: "key", app_secret: "secret", access_token: "token", shop_cipher: "cipher" }
    )
  end

  def stub_service_result(pending_count:, next_retry_at: nil)
    result = Integrations::Tiktok::PendingFinancialSyncService::Result.new(
      outcome: :success,
      error_message: nil,
      metadata: { "pending_count" => pending_count, "next_retry_at" => next_retry_at }
    )
    allow(Integrations::Tiktok::PendingFinancialSyncService).to receive(:call).and_return(result)
    result
  end

  it "returns without calling the service when the credential no longer exists" do
    allow(Integrations::Tiktok::PendingFinancialSyncService).to receive(:call)

    described_class.new.perform(-1)

    expect(Integrations::Tiktok::PendingFinancialSyncService).not_to have_received(:call)
  end

  it "does not schedule a continuation when nothing is left pending" do
    stub_service_result(pending_count: 0)
    allow(described_class).to receive(:set)

    described_class.new.perform(credential.id)

    expect(described_class).not_to have_received(:set)
  end

  # This is the behavior the rate-limit fix depends on: PendingFinancialSyncService#call
  # no longer raises Integrations::RateLimitError up to this job — it stops the
  # batch internally and reports the affected orders via metadata["pending_count"].
  # Recovery has to go through this continuation, not through the job's
  # (now minimal) retry_on Integrations::RateLimitError.
  it "schedules a continuation at next_retry_at when orders are still pending after a rate limit" do
    next_retry_at = 45.seconds.from_now
    stub_service_result(pending_count: 1, next_retry_at: next_retry_at)
    configured_job = double("configured_job")
    allow(described_class).to receive(:set).and_return(configured_job)
    allow(configured_job).to receive(:perform_later)

    described_class.new.perform(credential.id, batch_size: 10)

    expect(described_class).to have_received(:set) do |wait:|
      expect(wait).to be_within(1.second).of(next_retry_at - Time.current)
    end
    expect(configured_job).to have_received(:perform_later).with(
      credential.id, order_ids: nil, batch_size: 10, window_days: nil, run_id: kind_of(String)
    )
  end

  it "falls back to the service's base delay when metadata carries no next_retry_at" do
    stub_service_result(pending_count: 1, next_retry_at: nil)
    configured_job = double("configured_job")
    allow(described_class).to receive(:set).and_return(configured_job)
    allow(configured_job).to receive(:perform_later)

    described_class.new.perform(credential.id)

    expect(described_class).to have_received(:set)
      .with(wait: Integrations::Tiktok::PendingFinancialSyncService::RECENT_BASE_DELAY.to_i.seconds)
  end
end
