require "rails_helper"

RSpec.describe Integrations::Tiktok::ReturnRefundSyncJob do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-#{SecureRandom.hex(4)}") }
  let(:credential) do
    tenant.channel_credentials.create!(
      channel: "tiktok",
      status: "active",
      credentials: { app_key: "key", app_secret: "secret", access_token: "token", shop_cipher: "cipher" }
    )
  end

  it "delegates to ReturnRefundSyncService with the default window when none is given" do
    expect(Integrations::Tiktok::ReturnRefundSyncService).to receive(:call).with(
      credential,
      order_ids: nil,
      window_days: Integrations::Tiktok::ReturnRefundSyncService::DEFAULT_WINDOW_DAYS,
      trigger: "scheduled"
    )

    described_class.new.perform(credential.id)
  end

  it "passes through explicit order_ids/window_days/trigger" do
    expect(Integrations::Tiktok::ReturnRefundSyncService).to receive(:call).with(
      credential, order_ids: [ "order-1" ], window_days: 14, trigger: "manual"
    )

    described_class.new.perform(credential.id, order_ids: [ "order-1" ], window_days: 14, trigger: "manual")
  end

  it "does nothing when the credential no longer exists" do
    expect(Integrations::Tiktok::ReturnRefundSyncService).not_to receive(:call)

    described_class.new.perform(-1)
  end
end
