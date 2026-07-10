require "rails_helper"

RSpec.describe Integrations::Idworks::ProductCostSyncService do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:integration) do
    tenant.integrations.create!(
      provider: "idworks", name: "idworks", status: "connected",
      credentials: { base_url: "https://cliente.idworks.com.br/api/v1", api_key: "tok" }
    )
  end
  let(:products_fixture) { File.read(Rails.root.join("spec/fixtures/integrations/idworks_products.json")) }

  def stub_products
    stub_request(:get, "https://cliente.idworks.com.br/api/v1/products")
      .with(query: hash_including("page" => "1"))
      .to_return(status: 200, body: products_fixture, headers: { "Content-Type" => "application/json" })
  end

  before do
    tenant.products.create!(sku: "CAM-001-P-AZUL", name: "Camiseta", cost_price: 0)
    tenant.products.create!(sku: "CAN-001", name: "Caneca", cost_price: 0)
  end

  context "when cost and tax are both configured to idworks" do
    before do
      DataSourceConfig.ensure_default!(tenant, "cost", "idworks")
      DataSourceConfig.ensure_default!(tenant, "tax", "idworks")
      stub_products
    end

    it "applies cost_price and tax_rate onto matching products by sku" do
      result = described_class.call(integration)

      expect(result.success?).to eq(true)
      expect(result.synced_count).to eq(2)

      product = tenant.products.find_by(sku: "CAM-001-P-AZUL")
      expect(product.cost_price).to eq(BigDecimal("60.00"))
      expect(product.tax_rate).to eq(BigDecimal("8.5"))
    end
  end

  context "when cost is configured to a different source" do
    before do
      DataSourceConfig.ensure_default!(tenant, "cost", "pagarme") # nonsensical but proves the gate works
      stub_products
    end

    it "does not overwrite cost_price, since idworks isn't the configured source" do
      described_class.call(integration)

      expect(tenant.products.find_by(sku: "CAM-001-P-AZUL").cost_price).to eq(BigDecimal("0"))
    end
  end

  context "authentication failure" do
    it "marks the integration as errored" do
      stub_request(:get, "https://cliente.idworks.com.br/api/v1/products")
        .with(query: hash_including("page" => "1"))
        .to_return(status: 401, body: { message: "Unauthenticated" }.to_json)

      result = described_class.call(integration)

      expect(result.error?).to eq(true)
      expect(integration.reload.status).to eq("error")
    end
  end
end
