require "rails_helper"

# Endpoint paths, auth flow (POST user/signin/local -> Bearer + Origin/
# FilePath headers), and the confirmed field names (Sku/IDSku/
# CostLastPurchase/CostAverage on /sku; Order/IDOrder/ValueShipping on
# /orders) are verified against the tenant's real idworks Swagger spec
# (swagger.idworks.com.br) as of 2026-07-10 — see IdworksAdapter's class
# comment for what's still unverified (pagination envelope shape, exact
# DateFrom/DateTo format).
RSpec.describe Integrations::IdworksAdapter do
  let(:credentials) { { base_url: "https://cliente.idworks.com.br/1.0", email: "user@hidrabene.com", password: "secret" } }
  let(:adapter) { described_class.new(credentials) }
  let(:signin_url) { "https://cliente.idworks.com.br/1.0/user/signin/local" }
  let(:sku_url)    { "https://cliente.idworks.com.br/1.0/sku" }
  let(:orders_url) { "https://cliente.idworks.com.br/1.0/orders" }
  let(:signin_fixture) { File.read(Rails.root.join("spec/fixtures/integrations/idworks_signin.json")) }
  let(:sku_fixture)    { File.read(Rails.root.join("spec/fixtures/integrations/idworks_sku_list.json")) }
  let(:orders_fixture) { File.read(Rails.root.join("spec/fixtures/integrations/idworks_orders_list.json")) }

  def stub_signin(status: 200)
    stub_request(:post, signin_url)
      .with(
        headers: { "Origin" => "https://erp-www.idworks.com.br", "Filepath" => "" },
        body: { email: "user@hidrabene.com", password: "secret" }.to_json
      )
      .to_return(status: status, body: status == 200 ? signin_fixture : { message: "Invalid credentials" }.to_json,
                 headers: { "Content-Type" => "application/json" })
  end

  describe "#authenticate" do
    it "signs in via user/signin/local and returns true" do
      stub_signin

      expect(adapter.authenticate).to eq(true)
    end

    it "raises AuthenticationError when idworks rejects the credentials" do
      stub_signin(status: 401)

      expect { adapter.authenticate }.to raise_error(Integrations::AuthenticationError)
    end
  end

  describe "#fetch_products" do
    before do
      stub_signin
      stub_request(:get, sku_url)
        .with(query: hash_including("Page" => "1"), headers: { "Authorization" => "Bearer #{JSON.parse(signin_fixture)['token']}", "Origin" => "https://erp-www.idworks.com.br" })
        .to_return(status: 200, body: sku_fixture, headers: { "Content-Type" => "application/json" })
      stub_request(:get, sku_url).with(query: hash_including("Page" => "2"))
        .to_return(status: 200, body: { "Data" => [] }.to_json, headers: { "Content-Type" => "application/json" })
    end

    it "signs in first, then returns sku/cost_last_purchase/cost_average per product" do
      raws = adapter.fetch_products

      expect(raws).to include(
        hash_including(idworks_id: "12345", sku: "CAM-001-P-AZUL", cost_last_purchase: BigDecimal("60.00"), cost_average: BigDecimal("58.50")),
        hash_including(idworks_id: "12346", sku: "CAN-001", cost_last_purchase: nil, cost_average: BigDecimal("11.20"))
      )
    end

    it "extracts the stock fields per product, preserving a negative QtyAvailable as-is (real overselling signal, not clamped)" do
      raws = adapter.fetch_products
      camiseta = raws.find { |r| r[:sku] == "CAM-001-P-AZUL" }
      caneca   = raws.find { |r| r[:sku] == "CAN-001" }

      expect(camiseta).to include(
        qty_available: BigDecimal("-133.00"),
        qty_reserved: BigDecimal("0.000"),
        qty_safety_stock: nil,
        abc_curve: "C",
        lead_time_days: 0,
        infinite_inventory: false,
        last_modified_at: "2026-07-17T13:37:41.000Z"
      )
      expect(camiseta[:raw]).to include("QtyAvailable" => "-133.00")

      expect(caneca).to include(
        qty_available: BigDecimal("42.000"),
        qty_reserved: BigDecimal("5.000"),
        qty_safety_stock: BigDecimal("10.000"),
        abc_curve: "A",
        lead_time_days: 7,
        infinite_inventory: false
      )
    end

    it "stops paginating once a page comes back empty" do
      stub_request(:get, sku_url).with(query: hash_including("Page" => "2"))
        .to_return(status: 200, body: { "Data" => [] }.to_json, headers: { "Content-Type" => "application/json" })

      adapter.fetch_products
      expect(WebMock).to have_requested(:get, sku_url).with(query: hash_including("Page" => "2"))
      expect(WebMock).not_to have_requested(:get, sku_url).with(query: hash_including("Page" => "3"))
    end
  end

  describe "#fetch_orders" do
    before do
      stub_signin
      stub_request(:get, orders_url)
        .with(query: hash_including("Page" => "1", "DateFrom" => "2026-06-01T00:00:00Z", "DateTo" => "2026-06-01T02:00:00Z"))
        .to_return(status: 200, body: orders_fixture, headers: { "Content-Type" => "application/json" })
      stub_request(:get, orders_url).with(query: hash_including("Page" => "2"))
        .to_return(status: 200, body: { "Data" => [] }.to_json, headers: { "Content-Type" => "application/json" })
    end

    it "returns order_ref/idworks_order_id/value_shipping and related value fields" do
      orders = adapter.fetch_orders(from: Time.utc(2026, 6, 1, 0, 0, 0), to: Time.utc(2026, 6, 1, 2, 0, 0))

      expect(orders).to contain_exactly(
        { order_ref: "555001", idworks_order_id: "88001", value_shipping: BigDecimal("15.30"), value_product: BigDecimal("180.00"), value_order: BigDecimal("199.90"), value_paid: BigDecimal("199.90") },
        { order_ref: "555999-NOT-IN-PRICECOM", idworks_order_id: "88002", value_shipping: BigDecimal("0"), value_product: BigDecimal("29.90"), value_order: BigDecimal("29.90"), value_paid: BigDecimal("29.90") }
      )
    end
  end
end
