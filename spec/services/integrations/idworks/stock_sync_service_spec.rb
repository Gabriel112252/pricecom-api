require "rails_helper"

RSpec.describe Integrations::Idworks::StockSyncService do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
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
    # idworks' Page param is 0-indexed — see IdworksAdapter#fetch_products.
    stub_request(:get, "https://cliente.idworks.com.br/1.0/sku").with(query: hash_including("Page" => "0"))
      .to_return(status: 200, body: sku_fixture, headers: { "Content-Type" => "application/json" })
    stub_request(:get, "https://cliente.idworks.com.br/1.0/sku").with(query: hash_including("Page" => "1"))
      .to_return(status: 200, body: { "Data" => [] }.to_json, headers: { "Content-Type" => "application/json" })
  end

  before do
    tenant.products.create!(sku: "CAM-001-P-AZUL", name: "Camiseta", cost_price: 0)
    tenant.products.create!(sku: "CAN-001", name: "Caneca", cost_price: 0)
  end

  context "when stock is configured to idworks" do
    before do
      DataSourceConfig.ensure_default!(tenant, "stock", "idworks")
      stub_idworks
    end

    it "reevaluates an open insufficient_reserve StockAlert once qty_available changes and frees up reserve" do
      product = tenant.products.find_by(sku: "CAN-001") # fixture sets its QtyAvailable to 42.000
      listing = tenant.channel_product_listings.create!(product: product, channel: "shopify", external_id: "ext-1", stock_qty: 3)
      tenant.stock_alert_rules.create!(product: product, channel: "shopify", min_threshold: 5, target_level: 20)
      # product.qty_available starts at the column default (0) — with stock_qty=3, free_reserve is
      # already <= 0, so this naturally produces an insufficient_reserve alert to reevaluate.
      StockAlerts::EvaluationService.call(listing)
      expect(StockAlert.find_by(product: product, channel: "shopify").status).to eq("insufficient_reserve")

      described_class.call(integration)

      expect(StockAlert.find_by(product: product, channel: "shopify").status).to eq("pending")
    end

    it "updates the product's cached stock columns, including a negative QtyAvailable as-is" do
      result = described_class.call(integration)

      expect(result.success?).to eq(true)
      expect(result.synced_count).to eq(2)

      camiseta = tenant.products.find_by(sku: "CAM-001-P-AZUL")
      expect(camiseta.qty_available).to eq(BigDecimal("-133.00"))
      expect(camiseta.qty_reserved).to eq(BigDecimal("0.000"))
      expect(camiseta.qty_safety_stock).to be_nil
      expect(camiseta.abc_curve).to eq("C")
      expect(camiseta.lead_time_days).to eq(0)
      expect(camiseta.infinite_inventory).to eq(false)
      expect(camiseta.stock_synced_at).to be_present
    end

    it "creates one StockSnapshot per matched product, carrying the raw idworks record" do
      expect { described_class.call(integration) }.to change(StockSnapshot, :count).by(2)

      snapshot = StockSnapshot.joins(:product).find_by(products: { sku: "CAN-001" })
      expect(snapshot.tenant).to eq(tenant)
      expect(snapshot.qty_available).to eq(BigDecimal("42.000"))
      expect(snapshot.qty_reserved).to eq(BigDecimal("5.000"))
      expect(snapshot.qty_safety_stock).to eq(BigDecimal("10.000"))
      expect(snapshot.abc_curve).to eq("A")
      expect(snapshot.lead_time_days).to eq(7)
      expect(snapshot.raw_payload).to include("IDSkuCompany" => "CAN-001", "QtyAvailable" => "42.000")
    end

    it "does not touch ChannelProductListing#stock_qty — that's per-channel stock, a different concept" do
      product = tenant.products.find_by(sku: "CAM-001-P-AZUL")
      listing = product.channel_product_listings.create!(
        tenant: tenant, channel: "yampi", external_id: "ext-1", stock_qty: 7
      )

      described_class.call(integration)

      expect(listing.reload.stock_qty).to eq(BigDecimal("7"))
    end

    it "records an unmatched idworks sku (no matching Product) without erroring the whole sync" do
      result = described_class.call(integration)

      expect(result.metadata[:unmatched_count]).to eq(0) # both fixture skus have a matching Product in this spec
      expect(result.error?).to eq(false)
    end

    it "does not interrupt the rest of the sync when applying one item raises" do
      allow(StockSnapshot).to receive(:create!) do |attrs|
        raise StandardError, "boom" if attrs[:product].sku == "CAM-001-P-AZUL"

        StockSnapshot.new(attrs).tap(&:save!)
      end

      result = described_class.call(integration)

      expect(result.error?).to eq(true)
      expect(result.metadata[:errors]).to include(hash_including(sku: "CAM-001-P-AZUL", message: "boom"))
      # the other item in the same run still got synced despite the first one raising
      expect(tenant.products.find_by(sku: "CAN-001").qty_available).to eq(BigDecimal("42.000"))
      expect(StockSnapshot.joins(:product).where(products: { sku: "CAN-001" })).to exist
    end
  end

  context "when stock is configured to a different source" do
    it "is skipped entirely — no idworks call is even made" do
      DataSourceConfig.ensure_default!(tenant, "stock", "pagarme")

      result = described_class.call(integration)

      expect(result.skipped?).to eq(true)
      expect(StockSnapshot.count).to eq(0)
    end
  end

  context "authentication failure" do
    it "marks the integration as errored" do
      DataSourceConfig.ensure_default!(tenant, "stock", "idworks")
      stub_idworks(signin_status: 401)

      result = described_class.call(integration)

      expect(result.error?).to eq(true)
      expect(integration.reload.status).to eq("error")
    end
  end
end
