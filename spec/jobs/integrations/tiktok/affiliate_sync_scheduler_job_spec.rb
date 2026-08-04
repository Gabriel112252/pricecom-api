require "rails_helper"

RSpec.describe Integrations::Tiktok::AffiliateSyncSchedulerJob do
  it "enqueues an AffiliateSyncJob per active tiktok credential, skipping other channels and inactive ones" do
    tenant = Tenant.create!(name: "Loja Scheduler", slug: "loja-scheduler-#{SecureRandom.hex(4)}")
    pending_tenant = Tenant.create!(name: "Loja Pendente", slug: "loja-pendente-#{SecureRandom.hex(4)}")
    active_tiktok = tenant.channel_credentials.create!(
      channel: "tiktok", status: "active", credentials: { app_key: "k", app_secret: "s" }
    )
    pending_tenant.channel_credentials.create!(
      channel: "tiktok", status: "pending", credentials: { app_key: "k2", app_secret: "s2" }
    )
    tenant.channel_credentials.create!(
      channel: "shopee", status: "active", credentials: { partner_id: "1", partner_key: "2" }
    )
    allow(Integrations::Tiktok::AffiliateSyncJob).to receive(:perform_later)

    described_class.new.perform

    expect(Integrations::Tiktok::AffiliateSyncJob).to have_received(:perform_later).with(active_tiktok.id).once
  end
end
