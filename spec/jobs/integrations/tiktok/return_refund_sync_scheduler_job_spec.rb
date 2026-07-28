require "rails_helper"

RSpec.describe Integrations::Tiktok::ReturnRefundSyncSchedulerJob do
  def create_credential(channel:, status: "active")
    tenant = Tenant.create!(name: "Loja Teste", slug: "loja-#{SecureRandom.hex(4)}")
    credentials = channel == "tiktok" ?
      { app_key: "key", app_secret: "secret", access_token: "token", shop_cipher: "cipher" } :
      { alias: "a", token: "t", secret_key: "s", webhook_secret: "wh" }

    tenant.channel_credentials.create!(channel: channel, status: status, credentials: credentials)
  end

  it "enqueues one ReturnRefundSyncJob per active TikTok credential" do
    active = create_credential(channel: "tiktok")
    enqueued = []
    allow(Integrations::Tiktok::ReturnRefundSyncJob).to receive(:perform_later) do |id, **kwargs|
      enqueued << [ id, kwargs ]
    end

    described_class.new.perform

    expect(enqueued).to eq([ [ active.id, { trigger: "scheduled" } ] ])
  end

  it "skips credentials in error and non-TikTok channels" do
    create_credential(channel: "tiktok", status: "error")
    create_credential(channel: "yampi")
    allow(Integrations::Tiktok::ReturnRefundSyncJob).to receive(:perform_later)

    described_class.new.perform

    expect(Integrations::Tiktok::ReturnRefundSyncJob).not_to have_received(:perform_later)
  end
end
