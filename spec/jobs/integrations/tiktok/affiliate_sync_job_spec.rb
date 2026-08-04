require "rails_helper"

RSpec.describe Integrations::Tiktok::AffiliateSyncJob do
  let(:tenant) { Tenant.create!(name: "Loja Job", slug: "loja-afiliado-job-#{SecureRandom.hex(4)}") }
  let(:credential) do
    tenant.channel_credentials.create!(
      channel: "tiktok",
      status: "active",
      credentials: { app_key: "key", app_secret: "secret", access_token: "token", shop_cipher: "cipher" }
    )
  end

  it "returns without calling the service when the credential no longer exists" do
    allow(Integrations::Tiktok::AffiliateSyncService).to receive(:call)

    described_class.new.perform(-1)

    expect(Integrations::Tiktok::AffiliateSyncService).not_to have_received(:call)
  end

  it "calls the service for an existing credential" do
    allow(Integrations::Tiktok::AffiliateSyncService).to receive(:call)

    described_class.new.perform(credential.id)

    expect(Integrations::Tiktok::AffiliateSyncService).to have_received(:call).with(credential, run_id: kind_of(String))
  end

  it "reschedules itself using the rate limit's retry_after when the service raises RateLimitError" do
    allow(Integrations::Tiktok::AffiliateSyncService).to receive(:call)
      .and_raise(Integrations::RateLimitError.new("rate limited", retry_after: 90))
    configured_job = double("configured_job")
    allow(described_class).to receive(:set).and_return(configured_job)
    allow(configured_job).to receive(:perform_later)

    described_class.new.perform(credential.id)

    expect(described_class).to have_received(:set).with(wait: 90.seconds)
    expect(configured_job).to have_received(:perform_later).with(credential.id, run_id: kind_of(String))
  end

  it "clamps the reschedule wait to MIN/MAX bounds when retry_after is absent or extreme" do
    allow(Integrations::Tiktok::AffiliateSyncService).to receive(:call)
      .and_raise(Integrations::RateLimitError.new("rate limited", retry_after: nil))
    configured_job = double("configured_job")
    allow(described_class).to receive(:set).and_return(configured_job)
    allow(configured_job).to receive(:perform_later)

    described_class.new.perform(credential.id)

    expect(described_class).to have_received(:set).with(wait: described_class::DEFAULT_RATE_LIMIT_WAIT)
  end
end
