require "rails_helper"

RSpec.describe Integrations::Idworks::ScheduleOrderReconciliationJob do
  def make_integration(status: "connected")
    tenant = Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}")
    tenant.integrations.create!(
      provider: "idworks", name: "idworks", status: status,
      credentials: { base_url: "https://cliente.idworks.com.br/1.0", email: "u@x.com", password: "s" }
    )
  end

  it "enqueues OrderReconciliationJob only for connected idworks integrations whose tenant has order_reconciliation -> idworks" do
    enabled = make_integration
    DataSourceConfig.ensure_default!(enabled.tenant, "order_reconciliation", "idworks")

    disabled = make_integration
    DataSourceConfig.ensure_default!(disabled.tenant, "order_reconciliation", "pagarme")

    not_configured = make_integration

    disconnected = make_integration(status: "disconnected")
    DataSourceConfig.ensure_default!(disconnected.tenant, "order_reconciliation", "idworks")

    expect(Integrations::Idworks::OrderReconciliationJob)
      .to receive(:perform_later).with(enabled.id, 1.week.ago.to_date.iso8601, Date.current.iso8601)
    expect(Integrations::Idworks::OrderReconciliationJob).not_to receive(:perform_later).with(disabled.id, any_args)
    expect(Integrations::Idworks::OrderReconciliationJob).not_to receive(:perform_later).with(not_configured.id, any_args)
    expect(Integrations::Idworks::OrderReconciliationJob).not_to receive(:perform_later).with(disconnected.id, any_args)

    described_class.new.perform
  end

  it "ignores non-idworks integrations" do
    tenant = Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}")
    tenant.integrations.create!(provider: "generic", name: "outro", status: "connected", credentials: {})

    expect(Integrations::Idworks::OrderReconciliationJob).not_to receive(:perform_later)

    described_class.new.perform
  end
end
