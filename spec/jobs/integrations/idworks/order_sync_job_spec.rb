require "rails_helper"

RSpec.describe Integrations::Idworks::OrderSyncJob do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:integration) do
    tenant.integrations.create!(
      provider: "idworks", name: "idworks", status: "connected",
      credentials: { base_url: "https://cliente.idworks.com.br/1.0", email: "user@hidrabene.com", password: "secret" }
    )
  end

  it "calls OrderSyncService for the given integration" do
    expect(Integrations::Idworks::OrderSyncService).to receive(:call).with(integration)

    described_class.new.perform(integration.id)
  end

  it "does nothing when the integration no longer exists" do
    expect(Integrations::Idworks::OrderSyncService).not_to receive(:call)

    described_class.new.perform(-1)
  end
end
