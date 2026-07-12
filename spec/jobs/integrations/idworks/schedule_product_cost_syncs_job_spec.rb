require "rails_helper"

RSpec.describe Integrations::Idworks::ScheduleProductCostSyncsJob do
  def make_integration(status: "connected")
    tenant = Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}")
    tenant.integrations.create!(
      provider: "idworks", name: "idworks", status: status,
      credentials: { base_url: "https://cliente.idworks.com.br/1.0", email: "u@x.com", password: "s" }
    )
  end

  it "enqueues ProductCostSyncJob only for connected idworks integrations whose tenant has cost -> idworks" do
    enabled = make_integration
    DataSourceConfig.ensure_default!(enabled.tenant, "cost", "idworks")

    disabled = make_integration
    DataSourceConfig.ensure_default!(disabled.tenant, "cost", "pagarme")

    disconnected = make_integration(status: "disconnected")
    DataSourceConfig.ensure_default!(disconnected.tenant, "cost", "idworks")

    expect(Integrations::Idworks::ProductCostSyncJob).to receive(:perform_later).with(enabled.id)
    expect(Integrations::Idworks::ProductCostSyncJob).not_to receive(:perform_later).with(disabled.id)
    expect(Integrations::Idworks::ProductCostSyncJob).not_to receive(:perform_later).with(disconnected.id)

    described_class.new.perform
  end

  it "ignores non-idworks integrations" do
    tenant = Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}")
    tenant.integrations.create!(provider: "generic", name: "outro", status: "connected", credentials: {})

    expect(Integrations::Idworks::ProductCostSyncJob).not_to receive(:perform_later)

    described_class.new.perform
  end
end
