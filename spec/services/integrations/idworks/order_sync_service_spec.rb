require "rails_helper"

RSpec.describe Integrations::Idworks::OrderSyncService do
  let(:tenant)  { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:channel) { tenant.channels.create!(name: "Yampi", platform: "yampi") }
  let(:integration) do
    tenant.integrations.create!(
      provider: "idworks", name: "idworks", status: "connected",
      credentials: { base_url: "https://cliente.idworks.com.br/1.0", email: "user@hidrabene.com", password: "secret" }
    )
  end
  let(:signin_fixture) { File.read(Rails.root.join("spec/fixtures/integrations/idworks_signin.json")) }
  let(:orders_fixture) { File.read(Rails.root.join("spec/fixtures/integrations/idworks_orders_list.json")) }
  let!(:matching_order) do
    tenant.orders.create!(
      channel: channel, external_id: "555001", order_number: "555001",
      ordered_at: Time.current, gross_value: 199.90, freight: 19.90, order_type: "sale"
    )
  end

  def stub_idworks
    stub_request(:post, "https://cliente.idworks.com.br/1.0/user/signin/local")
      .to_return(status: 200, body: signin_fixture, headers: { "Content-Type" => "application/json" })
    stub_request(:get, "https://cliente.idworks.com.br/1.0/orders").with(query: hash_including("Page" => "1"))
      .to_return(status: 200, body: orders_fixture, headers: { "Content-Type" => "application/json" })
    stub_request(:get, "https://cliente.idworks.com.br/1.0/orders").with(query: hash_including("Page" => "2"))
      .to_return(status: 200, body: { "Data" => [] }.to_json, headers: { "Content-Type" => "application/json" })
  end

  context "when freight is configured to idworks" do
    before do
      DataSourceConfig.ensure_default!(tenant, "freight", "idworks")
      stub_idworks
    end

    it "sets real_freight_cost from ValueShipping for a matched order" do
      result = described_class.call(integration)

      expect(result.success?).to eq(true)
      expect(result.synced_count).to eq(1) # only 1 of 2 idworks orders matches a real Pricecom order
      expect(matching_order.reload.real_freight_cost).to eq(BigDecimal("15.30"))
    end

    it "recalculates margin using the newly-filled real_freight_cost" do
      described_class.call(integration)
      matching_order.reload

      expected_margin = matching_order.gross_value - matching_order.cost_price - matching_order.real_freight_cost - matching_order.discount - matching_order.commission - matching_order.operational_cost
      expect(matching_order.margin).to eq(expected_margin)
    end

    it "records an unmatched idworks order (not an error) instead of silently dropping it" do
      result = described_class.call(integration)

      unmatched = result.metadata[:unmatched] || result.metadata["unmatched"]
      expect(unmatched.any? { |u| (u[:idworks_ref] || u["idworks_ref"]) == "555999-NOT-IN-PRICECOM" }).to eq(true)
    end

    it "never touches tax_amount — idworks has no tax data" do
      described_class.call(integration)
      expect(matching_order.reload.tax_amount).to be_nil
    end
  end

  context "when freight is NOT configured to idworks" do
    it "is skipped entirely — no idworks call is even made" do
      DataSourceConfig.ensure_default!(tenant, "freight", "pagarme")

      result = described_class.call(integration)

      expect(result.skipped?).to eq(true)
      expect(matching_order.reload.real_freight_cost).to be_nil
    end
  end

  context "authentication failure" do
    it "marks the integration as errored" do
      DataSourceConfig.ensure_default!(tenant, "freight", "idworks")
      stub_request(:post, "https://cliente.idworks.com.br/1.0/user/signin/local")
        .to_return(status: 401, body: { message: "Invalid" }.to_json)

      result = described_class.call(integration)

      expect(result.error?).to eq(true)
      expect(integration.reload.status).to eq("error")
    end
  end
end
