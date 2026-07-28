require "rails_helper"

RSpec.describe Integrations::Tiktok::ShopAnalyticsSyncJob do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-#{SecureRandom.hex(4)}") }
  let(:credential) do
    tenant.channel_credentials.create!(
      channel: "tiktok",
      status: "active",
      credentials: { app_key: "key", app_secret: "secret", access_token: "token", shop_cipher: "cipher" }
    )
  end

  it "delegates to ShopAnalyticsSyncService with the default window when none is given" do
    expect(Integrations::Tiktok::ShopAnalyticsSyncService).to receive(:call).with(
      credential,
      window_days: Integrations::Tiktok::ShopAnalyticsSyncService::DEFAULT_WINDOW_DAYS,
      trigger:     "scheduled"
    )

    described_class.new.perform(credential.id)
  end

  it "passes through explicit window_days/trigger" do
    expect(Integrations::Tiktok::ShopAnalyticsSyncService).to receive(:call).with(
      credential, window_days: 7, trigger: "manual"
    )

    described_class.new.perform(credential.id, window_days: 7, trigger: "manual")
  end

  it "does nothing when the credential no longer exists" do
    expect(Integrations::Tiktok::ShopAnalyticsSyncService).not_to receive(:call)

    described_class.new.perform(-1)
  end
end
