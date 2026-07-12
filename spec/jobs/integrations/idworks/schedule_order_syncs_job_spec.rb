require "rails_helper"

RSpec.describe Integrations::Idworks::ScheduleOrderSyncsJob do
  def make_integration(status: "connected")
    tenant = Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}")
    tenant.integrations.create!(
      provider: "idworks", name: "idworks", status: status,
      credentials: { base_url: "https://cliente.idworks.com.br/1.0", email: "u@x.com", password: "s" }
    )
  end

  it "enqueues OrderSyncJob only for connected idworks integrations whose tenant has freight -> idworks" do
    enabled = make_integration
    DataSourceConfig.ensure_default!(enabled.tenant, "freight", "idworks")

    disabled = make_integration
    DataSourceConfig.ensure_default!(disabled.tenant, "freight", "pagarme")

    disconnected = make_integration(status: "disconnected")
    DataSourceConfig.ensure_default!(disconnected.tenant, "freight", "idworks")

    expect(Integrations::Idworks::OrderSyncJob).to receive(:perform_later).with(enabled.id)
    expect(Integrations::Idworks::OrderSyncJob).not_to receive(:perform_later).with(disabled.id)
    expect(Integrations::Idworks::OrderSyncJob).not_to receive(:perform_later).with(disconnected.id)

    described_class.new.perform
  end
end
