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
        external_id:                "808950810",
        external_sku:               "IPOD2008PINK",
        name:                       "IPod Nano - 8GB",
        price:                      BigDecimal("199.00"),
        stock_qty:                  BigDecimal("10"),
        external_inventory_item_id: "39072856"
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

  describe "#update_stock" do
    let(:locations_url) { "#{base_url}/locations.json" }
    let(:inventory_levels_url) { "#{base_url}/inventory_levels/set.json" }

    def stub_single_location(id: 655441, active: true, legacy: false)
      stub_request(:get, locations_url)
        .to_return(status: 200, body: { locations: [ { id: id, name: "Loja principal", active: active, legacy: legacy } ] }.to_json,
                   headers: { "Content-Type" => "application/json" })
    end

    it "sets the absolute inventory level via inventory_levels/set.json, resolving the store's single active location" do
      stub_single_location(id: 655441)
      stub_request(:post, inventory_levels_url)
        .with(body: { location_id: 655441, inventory_item_id: 39072856, available: 7 }.to_json)
        .to_return(status: 200, body: { inventory_level: { available: 7, location_id: 655441, inventory_item_id: 39072856 } }.to_json,
                   headers: { "Content-Type" => "application/json" })

      result = adapter.update_stock(external_id: "808950810", quantity: 7, inventory_item_id: "39072856")

      expect(result).to eq(7)
      expect(WebMock).to have_requested(:post, inventory_levels_url)
        .with(body: { location_id: 655441, inventory_item_id: 39072856, available: 7 }.to_json)
    end

    it "memoizes the resolved location across multiple writes in the same adapter instance" do
      stub_single_location(id: 655441)
      stub_request(:post, inventory_levels_url)
        .to_return(status: 200, body: { inventory_level: { available: 1 } }.to_json, headers: { "Content-Type" => "application/json" })

      adapter.update_stock(external_id: "808950810", quantity: 1, inventory_item_id: "39072856")
      adapter.update_stock(external_id: "808950811", quantity: 2, inventory_item_id: "39072857")

      expect(WebMock).to have_requested(:get, locations_url).once
    end

    it "raises ApiError instead of guessing when the store has more than one active, non-legacy location" do
      stub_request(:get, locations_url)
        .to_return(status: 200, body: { locations: [
          { id: 1, active: true, legacy: false },
          { id: 2, active: true, legacy: false }
        ] }.to_json, headers: { "Content-Type" => "application/json" })

      expect { adapter.update_stock(external_id: "808950810", quantity: 7, inventory_item_id: "39072856") }
        .to raise_error(Integrations::ApiError, /expected exactly one active, non-legacy location/)
    end

    it "excludes inactive and legacy (fulfillment-service) locations before picking one" do
      stub_request(:get, locations_url)
        .to_return(status: 200, body: { locations: [
          { id: 1, active: false, legacy: false },
          { id: 2, active: true, legacy: true },
          { id: 3, active: true, legacy: false }
        ] }.to_json, headers: { "Content-Type" => "application/json" })
      stub_request(:post, inventory_levels_url)
        .with(body: hash_including("location_id" => 3))
        .to_return(status: 200, body: { inventory_level: { available: 7 } }.to_json, headers: { "Content-Type" => "application/json" })

      adapter.update_stock(external_id: "808950810", quantity: 7, inventory_item_id: "39072856")

      expect(WebMock).to have_requested(:post, inventory_levels_url).with(body: hash_including("location_id" => 3))
    end

    it "raises AuthenticationError on 401, same as every other adapter method" do
      stub_single_location
      stub_request(:post, inventory_levels_url).to_return(status: 401, body: { errors: "Invalid API key or access token" }.to_json)

      expect { adapter.update_stock(external_id: "808950810", quantity: 7, inventory_item_id: "39072856") }
        .to raise_error(Integrations::AuthenticationError)
    end
  end
end
