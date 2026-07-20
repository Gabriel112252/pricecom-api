require "rails_helper"

RSpec.describe Integrations::Idworks::ScheduleStockSyncsJob do
  def make_integration(status: "connected")
    tenant = Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}")
    tenant.integrations.create!(
      provider: "idworks", name: "idworks", status: status,
      credentials: { base_url: "https://cliente.idworks.com.br/1.0", email: "u@x.com", password: "s" }
    )
  end

  it "enqueues StockSyncJob only for connected idworks integrations whose tenant has stock -> idworks" do
    enabled = make_integration
    DataSourceConfig.ensure_default!(enabled.tenant, "stock", "idworks")

    disabled = make_integration
    DataSourceConfig.ensure_default!(disabled.tenant, "stock", "pagarme")

    disconnected = make_integration(status: "disconnected")
    DataSourceConfig.ensure_default!(disconnected.tenant, "stock", "idworks")

    expect(Integrations::Idworks::StockSyncJob).to receive(:perform_later).with(enabled.id)
    expect(Integrations::Idworks::StockSyncJob).not_to receive(:perform_later).with(disabled.id)
    expect(Integrations::Idworks::StockSyncJob).not_to receive(:perform_later).with(disconnected.id)

    described_class.new.perform
  end

  it "ignores non-idworks integrations" do
    tenant = Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}")
    tenant.integrations.create!(provider: "generic", name: "outro", status: "connected", credentials: {})

    expect(Integrations::Idworks::StockSyncJob).not_to receive(:perform_later)

    described_class.new.perform
  end
end
