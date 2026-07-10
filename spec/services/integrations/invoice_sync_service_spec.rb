require "rails_helper"

RSpec.describe Integrations::InvoiceSyncService do
  let(:tenant)  { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:channel) { tenant.channels.create!(name: "Yampi", platform: "yampi") }
  let(:integration) do
    tenant.integrations.create!(
      provider: "idworks", name: "idworks", status: "connected",
      credentials: { base_url: "https://cliente.idworks.com.br/api/v1", api_key: "tok" }
    )
  end
  let(:invoice_fixture) { File.read(Rails.root.join("spec/fixtures/integrations/idworks_invoice.json")) }
  let!(:order) do
    tenant.orders.create!(
      channel: channel, external_id: "555001", order_number: "555001",
      ordered_at: Time.current, gross_value: 199.90, freight: 19.90, order_type: "sale"
    )
  end

  def stub_invoice(order_ref: "555001", body: invoice_fixture)
    stub_request(:get, "https://cliente.idworks.com.br/api/v1/invoices")
      .with(query: hash_including("order_ref" => order_ref))
      .to_return(status: 200, body: body, headers: { "Content-Type" => "application/json" })
  end

  before do
    # authenticate() hits /products with per_page=1
    stub_request(:get, "https://cliente.idworks.com.br/api/v1/products")
      .with(query: hash_including("page" => "1", "per_page" => "1"))
      .to_return(status: 200, body: { data: [] }.to_json, headers: { "Content-Type" => "application/json" })
  end

  context "when freight and tax are both configured to idworks" do
    before do
      DataSourceConfig.ensure_default!(tenant, "freight", "idworks")
      DataSourceConfig.ensure_default!(tenant, "tax", "idworks")
      stub_invoice
    end

    it "fills nf_number and, since idworks owns freight/tax, real_freight_cost/tax_amount" do
      result = described_class.call(integration)

      expect(result.success?).to eq(true)
      expect(result.synced_count).to eq(1)

      order.reload
      expect(order.nf_number).to eq("NF-000123")
      expect(order.nf_freight).to eq(BigDecimal("19.90"))
      expect(order.real_freight_cost).to eq(BigDecimal("15.30"))
      expect(order.tax_amount).to eq(BigDecimal("12.50"))
    end

    it "recalculates margin using the newly-filled real_freight_cost/tax_amount" do
      described_class.call(integration)
      order.reload

      expected_margin = order.gross_value - order.cost_price - order.real_freight_cost - order.discount - order.commission - order.operational_cost - order.tax_amount
      expect(order.margin).to eq(expected_margin)
    end
  end

  context "when freight is NOT configured to idworks" do
    before do
      DataSourceConfig.ensure_default!(tenant, "freight", "pagarme") # arbitrary other source
      stub_invoice
    end

    it "still fills nf_number/nf_freight (the invoice itself) but leaves real_freight_cost untouched" do
      described_class.call(integration)
      order.reload

      expect(order.nf_number).to eq("NF-000123") # NF matching is unconditional
      expect(order.real_freight_cost).to be_nil   # but the freight-cost figure isn't, since idworks isn't the configured source
    end
  end

  context "when idworks has no invoice for this order yet" do
    before { stub_invoice(body: { data: nil }.to_json) }

    it "leaves the order's NF fields blank and doesn't count it as synced" do
      result = described_class.call(integration)

      expect(result.synced_count).to eq(0)
      expect(order.reload.nf_number).to be_nil
    end
  end

  it "falls back to the pre-existing margin calculation for an order idworks never syncs (freight, no real_freight_cost)" do
    # No sync ever runs for this order — proves Order#calculate_margin's fallback independent of the service.
    expect(order.real_freight_cost).to be_nil
    expect(order.margin).to eq(order.gross_value - order.cost_price - order.freight - order.discount - order.commission - order.operational_cost)
  end
end
