require "rails_helper"

RSpec.describe Integrations::Tiktok::AffiliateVideoSyncJob do
  let(:tenant) { Tenant.create!(name: "Loja Vídeos Job", slug: "loja-videos-job-#{SecureRandom.hex(4)}") }
  let(:credential) do
    tenant.channel_credentials.create!(
      channel: "tiktok",
      status: "active",
      credentials: { app_key: "key", app_secret: "secret", access_token: "token", shop_cipher: "cipher" }
    )
  end

  before do
    allow(Integrations::Tiktok::AffiliateSyncService).to receive(:call)
    allow(Integrations::Tiktok::AffiliateVideoSyncService).to receive(:call)
  end

  def creator_sync_log(finished_at:, status: "success", credential_id: credential.id)
    IntegrationSyncLog.create!(
      tenant: tenant,
      direction: "inbound",
      action: Integrations::Tiktok::AffiliateSyncService::ACTION,
      status: status,
      started_at: finished_at - 5.minutes,
      finished_at: finished_at,
      metadata: { "channel_credential_id" => credential_id }
    )
  end

  it "returns without calling either service when the credential no longer exists" do
    described_class.new.perform(-1)

    expect(Integrations::Tiktok::AffiliateSyncService).not_to have_received(:call)
    expect(Integrations::Tiktok::AffiliateVideoSyncService).not_to have_received(:call)
  end

  it "refreshes the creators, then syncs the videos, when no creator sync succeeded recently" do
    creator_sync_log(finished_at: (described_class::CREATORS_FRESH_FOR + 1.hour).ago)

    described_class.new.perform(credential.id, days_back: 30)

    expect(Integrations::Tiktok::AffiliateSyncService).to have_received(:call).with(credential, run_id: kind_of(String))
    expect(Integrations::Tiktok::AffiliateVideoSyncService).to have_received(:call).with(credential, days_back: 30)
  end

  it "skips the creator refresh when one succeeded for this credential within CREATORS_FRESH_FOR" do
    creator_sync_log(finished_at: 1.hour.ago)

    described_class.new.perform(credential.id, days_back: 30)

    expect(Integrations::Tiktok::AffiliateSyncService).not_to have_received(:call)
    expect(Integrations::Tiktok::AffiliateVideoSyncService).to have_received(:call).with(credential, days_back: 30)
  end

  it "does not count a recent creator sync that failed or belongs to another credential" do
    creator_sync_log(finished_at: 1.hour.ago, status: "error")
    creator_sync_log(finished_at: 1.hour.ago, credential_id: credential.id + 1000)

    described_class.new.perform(credential.id, days_back: 30)

    expect(Integrations::Tiktok::AffiliateSyncService).to have_received(:call)
  end

  it "skips the creator refresh when sync_creators is false" do
    described_class.new.perform(credential.id, days_back: 30, sync_creators: false)

    expect(Integrations::Tiktok::AffiliateSyncService).not_to have_received(:call)
    expect(Integrations::Tiktok::AffiliateVideoSyncService).to have_received(:call).with(credential, days_back: 30)
  end

  it "reschedules only the video sync (sync_creators: false) on a rate limit" do
    allow(Integrations::Tiktok::AffiliateVideoSyncService).to receive(:call)
      .and_raise(Integrations::RateLimitError.new("rate limited", retry_after: 90))
    configured_job = double("configured_job")
    allow(described_class).to receive(:set).and_return(configured_job)
    allow(configured_job).to receive(:perform_later)

    described_class.new.perform(credential.id, days_back: 30)

    expect(described_class).to have_received(:set).with(wait: 90.seconds)
    expect(configured_job).to have_received(:perform_later).with(credential.id, days_back: 30, sync_creators: false)
  end
end
