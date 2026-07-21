require "rails_helper"

RSpec.describe Integrations::Tiktok::DiscountBackfillJob do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:credential) do
    tenant.channel_credentials.create!(
      channel: "tiktok",
      status: "active",
      credentials: { app_key: "key", app_secret: "secret", access_token: "tok", shop_cipher: "cipher" }
    )
  end

  it "calls DiscountBackfillService with the tenant's tiktok credential" do
    credential
    expect(Integrations::Tiktok::DiscountBackfillService).to receive(:call).with(
      an_object_having_attributes(id: credential.id)
    )

    described_class.new.perform(tenant_id: tenant.id)
  end

  it "does nothing when the tenant no longer exists" do
    expect(Integrations::Tiktok::DiscountBackfillService).not_to receive(:call)

    described_class.new.perform(tenant_id: -1)
  end

  it "does nothing when the tenant has no tiktok ChannelCredential" do
    expect(Integrations::Tiktok::DiscountBackfillService).not_to receive(:call)

    described_class.new.perform(tenant_id: tenant.id)
  end
end
