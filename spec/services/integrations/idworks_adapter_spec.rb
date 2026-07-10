require "rails_helper"

# NOTE: unlike the other adapter specs in this directory (Yampi/Shopify/
# etc.), there is no real idworks API documentation to verify this fixture
# shape against — see IdworksAdapter's class comment. These assertions
# only prove the adapter behaves consistently with itself, not that it
# matches a real idworks account.
RSpec.describe Integrations::IdworksAdapter do
  let(:credentials) { { base_url: "https://cliente.idworks.com.br/api/v1", api_key: "tok123" } }
  let(:adapter) { described_class.new(credentials) }
  let(:products_url) { "https://cliente.idworks.com.br/api/v1/products" }
  let(:invoices_url)  { "https://cliente.idworks.com.br/api/v1/invoices" }
  let(:products_fixture) { File.read(Rails.root.join("spec/fixtures/integrations/idworks_products.json")) }
  let(:invoice_fixture)  { File.read(Rails.root.join("spec/fixtures/integrations/idworks_invoice.json")) }

  describe "#authenticate" do
    it "returns true when idworks accepts the credentials" do
      stub_request(:get, products_url)
        .with(query: hash_including("page" => "1", "per_page" => "1"), headers: { "Authorization" => "Bearer tok123" })
        .to_return(status: 200, body: products_fixture, headers: { "Content-Type" => "application/json" })

      expect(adapter.authenticate).to eq(true)
    end

    it "raises AuthenticationError on 401" do
      stub_request(:get, products_url).with(query: hash_including("page" => "1"))
        .to_return(status: 401, body: { message: "Unauthenticated" }.to_json)

      expect { adapter.authenticate }.to raise_error(Integrations::AuthenticationError)
    end
  end

  describe "#fetch_products_with_cost" do
    it "returns sku/cost/tax_rate for each product" do
      stub_request(:get, products_url).with(query: hash_including("page" => "1"))
        .to_return(status: 200, body: products_fixture, headers: { "Content-Type" => "application/json" })

      raws = adapter.fetch_products_with_cost

      expect(raws).to contain_exactly(
        { sku: "CAM-001-P-AZUL", cost: BigDecimal("60.00"), tax_rate: BigDecimal("8.5") },
        { sku: "CAN-001", cost: BigDecimal("12.00"), tax_rate: BigDecimal("6.0") }
      )
    end

    it "paginates until total_pages is reached" do
      page1 = JSON.parse(products_fixture)
      page1["meta"]["pagination"] = page1["meta"]["pagination"].merge("current_page" => 1, "total_pages" => 2)
      page2 = { "data" => [ { "sku" => "EXTRA-1", "cost" => 5.0, "tax_rate" => 4.0 } ],
                "meta" => { "pagination" => { "current_page" => 2, "total_pages" => 2 } } }
      json_headers = { "Content-Type" => "application/json" }

      stub_request(:get, products_url).with(query: hash_including("page" => "1")).to_return(status: 200, body: page1.to_json, headers: json_headers)
      stub_request(:get, products_url).with(query: hash_including("page" => "2")).to_return(status: 200, body: page2.to_json, headers: json_headers)

      raws = adapter.fetch_products_with_cost
      expect(raws.map { |r| r[:sku] }).to include("CAM-001-P-AZUL", "EXTRA-1")
    end
  end

  describe "#fetch_invoices" do
    it "returns the invoice fields for a matched order" do
      stub_request(:get, invoices_url).with(query: hash_including("order_ref" => "555001"))
        .to_return(status: 200, body: invoice_fixture, headers: { "Content-Type" => "application/json" })

      invoice = adapter.fetch_invoices("555001")

      expect(invoice).to eq(
        nf_number: "NF-000123",
        nf_gross_value: BigDecimal("199.90"),
        nf_discount: BigDecimal("0.0"),
        nf_freight: BigDecimal("19.90"),
        tax_amount: BigDecimal("12.50"),
        real_freight_cost: BigDecimal("15.30")
      )
    end

    it "returns nil when idworks hasn't matched an invoice to this order yet" do
      stub_request(:get, invoices_url).with(query: hash_including("order_ref" => "999999"))
        .to_return(status: 200, body: { data: nil }.to_json, headers: { "Content-Type" => "application/json" })

      expect(adapter.fetch_invoices("999999")).to be_nil
    end
  end
end
