require "rails_helper"

RSpec.describe Integrations::Idworks::OrderReconciliationJob do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:integration) do
    tenant.integrations.create!(
      provider: "idworks", name: "idworks", status: "connected",
      credentials: { base_url: "https://cliente.idworks.com.br/1.0", email: "user@hidrabene.com", password: "secret" }
    )
  end

  it "calls OrderReconciliationService for the given integration's tenant and period" do
    expect(Reconciliation::OrderReconciliationService).to receive(:call).with(
      tenant: tenant, period_from: Date.new(2026, 7, 20), period_to: Date.new(2026, 7, 27)
    )

    described_class.new.perform(integration.id, "2026-07-20", "2026-07-27")
  end

  it "does nothing when the integration no longer exists" do
    expect(Reconciliation::OrderReconciliationService).not_to receive(:call)

    described_class.new.perform(-1, "2026-07-20", "2026-07-27")
  end
end
