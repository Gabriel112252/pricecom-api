require "rails_helper"

RSpec.describe Integrations::ProductSyncJob do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-#{SecureRandom.hex(4)}") }

  it "returns without error and logs when the channel has no adapter" do
    credential = tenant.channel_credentials.create!(
      channel: "lucrofrete",
      status: "active",
      credentials: { email: "frete@example.com", password: "password" }
    )

    expect(Integrations::ProductSyncService).not_to receive(:call)
    expect(Rails.logger).to receive(:info).with(
      include("credential_id=#{credential.id}", "channel=lucrofrete")
    )

    expect { described_class.new.perform(credential.id) }.not_to raise_error
    expect(credential.reload.status).to eq("active")
  end

  it "calls ProductSyncService for a supported channel" do
    credential = tenant.channel_credentials.create!(
      channel: "shopify",
      status: "active",
      credentials: { shop_domain: "loja.myshopify.com", access_token: "token", webhook_secret: "webhook" }
    )

    expect(Integrations::ProductSyncService).to receive(:call).with(credential)

    described_class.new.perform(credential.id)
  end

  it "returns when the credential no longer exists" do
    expect(Integrations::ProductSyncService).not_to receive(:call)

    expect { described_class.new.perform(-1) }.not_to raise_error
  end
end
