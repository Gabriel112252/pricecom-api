require "rails_helper"

# All assertions here run against the mocked payload in
# spec/fixtures/integrations/shopify_products.json (shape verified against
# shopify.dev/docs/api/admin-rest/latest/resources/product on 2026-07-09 —
# see ShopifyAdapter's class comment). No real Shopify store is contacted
# or verified anywhere in this spec.
RSpec.describe Integrations::ShopifyAdapter do
  let(:credentials) { { shop_domain: "minha-loja.myshopify.com", access_token: "shpat_abc123" } }
  let(:adapter) { described_class.new(credentials) }
  let(:base_url) { "https://minha-loja.myshopify.com/admin/api/2024-01" }
  let(:fixture_body) { File.read(Rails.root.join("spec/fixtures/integrations/shopify_products.json")) }

  describe "#authenticate" do
    it "returns true when the channel accepts the credentials" do
      stub_request(:get, "#{base_url}/shop.json")
        .with(headers: { "X-Shopify-Access-Token" => "shpat_abc123" })
        .to_return(status: 200, body: { shop: { id: 1 } }.to_json, headers: { "Content-Type" => "application/json" })

      expect(adapter.authenticate).to eq(true)
    end

    it "raises AuthenticationError on 401" do
      stub_request(:get, "#{base_url}/shop.json")
        .to_return(status: 401, body: { errors: "Invalid API key or access token" }.to_json)

      expect { adapter.authenticate }.to raise_error(Integrations::AuthenticationError)
    end

    it "raises AuthenticationError on 403" do
      stub_request(:get, "#{base_url}/shop.json")
        .to_return(status: 403, body: { errors: "Forbidden" }.to_json)

      expect { adapter.authenticate }.to raise_error(Integrations::AuthenticationError)
    end

    it "raises RateLimitError on 429 and captures Retry-After" do
      stub_request(:get, "#{base_url}/shop.json")
        .to_return(status: 429, body: { errors: "Too Many Requests" }.to_json, headers: { "Retry-After" => "2" })

      expect { adapter.authenticate }.to raise_error(Integrations::RateLimitError) do |error|
        expect(error.retry_after).to eq(2)
      end
    end
  end

  describe "#fetch_products / #normalize_product" do
    it "flattens each product's variants into one raw record per SKU" do
      stub_request(:get, "#{base_url}/products.json")
        .with(query: hash_including("limit" => "250"))
        .to_return(status: 200, body: fixture_body, headers: { "Content-Type" => "application/json" })

      raws = adapter.fetch_products
      expect(raws.size).to eq(3)
    end

    it "normalizes a variant correctly" do
      stub_request(:get, "#{base_url}/products.json")
        .with(query: hash_including("limit" => "250"))
        .to_return(status: 200, body: fixture_body, headers: { "Content-Type" => "application/json" })

      raw = adapter.fetch_products.find { |r| r["sku"] == "IPOD2008PINK" }

      expect(adapter.normalize_product(raw)).to include(
        external_id:  "808950810",
        external_sku: "IPOD2008PINK",
        name:         "IPod Nano - 8GB",
        price:        BigDecimal("199.00"),
        stock_qty:    BigDecimal("10")
      )
    end

    it "follows the Link header for cursor pagination" do
      page2 = { "products" => [ { "id" => 999, "title" => "Extra", "variants" => [ { "id" => 1, "sku" => "EXTRA-1", "price" => "10.00", "inventory_quantity" => 1 } ] } ] }
      next_link = "<#{base_url}/products.json?limit=250&page_info=abc123>; rel=\"next\""

      stub_request(:get, "#{base_url}/products.json")
        .with(query: hash_including("limit" => "250"))
        .to_return(status: 200, body: fixture_body, headers: { "Content-Type" => "application/json", "Link" => next_link })

      stub_request(:get, "#{base_url}/products.json")
        .with(query: hash_including("page_info" => "abc123"))
        .to_return(status: 200, body: page2.to_json, headers: { "Content-Type" => "application/json" })

      raws = adapter.fetch_products
      expect(raws.map { |r| r["sku"] }).to include("IPOD2008PINK", "EXTRA-1")
    end
  end
end
