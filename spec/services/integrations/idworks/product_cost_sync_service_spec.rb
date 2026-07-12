require "rails_helper"

RSpec.describe Integrations::Idworks::ProductCostSyncService do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:channel) { tenant.channels.create!(name: "Yampi", platform: "yampi") }
  let(:integration) do
    tenant.integrations.create!(
      provider: "idworks", name: "idworks", status: "connected",
      credentials: { base_url: "https://cliente.idworks.com.br/1.0", email: "user@hidrabene.com", password: "secret" }
    )
  end
  let(:signin_fixture) { File.read(Rails.root.join("spec/fixtures/integrations/idworks_signin.json")) }
  let(:sku_fixture)    { File.read(Rails.root.join("spec/fixtures/integrations/idworks_sku_list.json")) }

  def stub_idworks(signin_status: 200)
    stub_request(:post, "https://cliente.idworks.com.br/1.0/user/signin/local")
      .to_return(status: signin_status, body: signin_status == 200 ? signin_fixture : { message: "Invalid" }.to_json,
                 headers: { "Content-Type" => "application/json" })
    stub_request(:get, "https://cliente.idworks.com.br/1.0/sku").with(query: hash_including("Page" => "1"))
      .to_return(status: 200, body: sku_fixture, headers: { "Content-Type" => "application/json" })
    stub_request(:get, "https://cliente.idworks.com.br/1.0/sku").with(query: hash_including("Page" => "2"))
      .to_return(status: 200, body: { "Data" => [] }.to_json, headers: { "Content-Type" => "application/json" })
  end

  before do
    tenant.products.create!(sku: "CAM-001-P-AZUL", name: "Camiseta", cost_price: 0)
    tenant.products.create!(sku: "CAN-001", name: "Caneca", cost_price: 0)
  end

  context "when cost is configured to idworks" do
    before do
      DataSourceConfig.ensure_default!(tenant, "cost", "idworks")
      stub_idworks
    end

    it "applies CostLastPurchase as cost_price when present" do
      result = described_class.call(integration)

      expect(result.success?).to eq(true)
      expect(result.synced_count).to eq(2)
      expect(tenant.products.find_by(sku: "CAM-001-P-AZUL").cost_price).to eq(BigDecimal("60.00"))
    end

    it "falls back to CostAverage when CostLastPurchase is absent" do
      described_class.call(integration)

      expect(tenant.products.find_by(sku: "CAN-001").cost_price).to eq(BigDecimal("11.20"))
    end

    it "propagates product cost to matching order items and recalculates order margin" do
      product = tenant.products.find_by(sku: "CAM-001-P-AZUL")
      order = tenant.orders.create!(
        channel: channel,
        external_id: "ORDER-1",
        order_number: "ORDER-1",
        gross_value: 150,
        freight: 10,
        ordered_at: Time.current,
        order_type: "sale"
      )
      order.order_items.create!(product: product, sku: product.sku, name: product.name, quantity: 2, unit_price: 75, unit_cost: nil)

      result = described_class.call(integration)

      expect(result.metadata[:order_items_updated_count]).to eq(1)
      expect(order.order_items.first.reload.unit_cost).to eq(BigDecimal("60.00"))
      expect(order.reload.cost_price).to eq(BigDecimal("120.00"))
      expect(order.margin).to eq(BigDecimal("20.0"))
    end

    it "never touches tax_rate — idworks has no usable tax field" do
      product = tenant.products.find_by(sku: "CAM-001-P-AZUL")
      product.update!(tax_rate: 9.99)

      described_class.call(integration)

      expect(product.reload.tax_rate).to eq(BigDecimal("9.99")) # untouched
    end
  end

  context "when cost is configured to a different source" do
    it "is skipped entirely — no idworks call is even made" do
      DataSourceConfig.ensure_default!(tenant, "cost", "pagarme")

      result = described_class.call(integration)

      expect(result.skipped?).to eq(true)
      expect(tenant.products.find_by(sku: "CAM-001-P-AZUL").cost_price).to eq(BigDecimal("0"))
    end
  end

  context "authentication failure" do
    it "marks the integration as errored" do
      DataSourceConfig.ensure_default!(tenant, "cost", "idworks")
      stub_idworks(signin_status: 401)

      result = described_class.call(integration)

      expect(result.error?).to eq(true)
      expect(integration.reload.status).to eq("error")
    end
  end
end
