require "rails_helper"

RSpec.describe Integrations::Tiktok::PendingFinancialSyncSchedulerJob do
  def create_credential(status: "active")
    tenant = Tenant.create!(name: "Loja Teste", slug: "loja-#{SecureRandom.hex(4)}")
    tenant.channel_credentials.create!(
      channel: "tiktok",
      status: status,
      credentials: { app_key: "key", app_secret: "secret", access_token: "token", shop_cipher: "cipher" }
    )
  end

  it "enqueues one PendingFinancialSyncJob per active TikTok credential with the small scheduled batch" do
    active = create_credential
    enqueued = []
    allow(Integrations::Tiktok::PendingFinancialSyncJob).to receive(:perform_later) do |id, **kwargs|
      enqueued << [ id, kwargs ]
    end

    described_class.new.perform

    expect(enqueued).to eq([ [ active.id, { batch_size: described_class::SCHEDULED_BATCH_SIZE } ] ])
    expect(described_class::SCHEDULED_BATCH_SIZE).to eq(25)
  end

  it "skips credentials in error and non-TikTok channels" do
    create_credential(status: "error")
    yampi_tenant = Tenant.create!(name: "Loja Yampi", slug: "loja-#{SecureRandom.hex(4)}")
    yampi_tenant.channel_credentials.create!(
      channel: "yampi",
      status: "active",
      credentials: { alias: "a", token: "t", secret_key: "s", webhook_secret: "wh" }
    )
    allow(Integrations::Tiktok::PendingFinancialSyncJob).to receive(:perform_later)

    described_class.new.perform

    expect(Integrations::Tiktok::PendingFinancialSyncJob).not_to have_received(:perform_later)
  end
end
