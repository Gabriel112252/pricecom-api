require "rails_helper"

RSpec.describe Integrations::Idworks::ProductCostSyncJob do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:integration) do
    tenant.integrations.create!(
      provider: "idworks", name: "idworks", status: "connected",
      credentials: { base_url: "https://cliente.idworks.com.br/1.0", email: "user@hidrabene.com", password: "secret" }
    )
  end

  it "calls ProductCostSyncService for the given integration" do
    expect(Integrations::Idworks::ProductCostSyncService).to receive(:call).with(integration)

    described_class.new.perform(integration.id)
  end

  it "does nothing when the integration no longer exists" do
    expect(Integrations::Idworks::ProductCostSyncService).not_to receive(:call)

    described_class.new.perform(-1)
  end
end
