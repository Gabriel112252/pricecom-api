require "rails_helper"

# ⚠️ See MercadoLivreAdapter's class comment: the real ML docs couldn't be
# fetched in this environment, so these assertions only prove the adapter
# parses/handles the shape it itself assumes — not that the design matches
# Mercado Livre's actual API. No real ML call is made anywhere in this spec.
RSpec.describe Integrations::MercadoLivreAdapter do
  let(:credentials) { { user_id: "789", access_token: "APP_USR-token" } }
  let(:adapter) { described_class.new(credentials) }
  let(:search_url) { "https://api.mercadolibre.com/users/789/items/search" }
  let(:items_url) { "https://api.mercadolibre.com/items" }
  let(:search_body) { File.read(Rails.root.join("spec/fixtures/integrations/mercado_livre_search.json")) }
  let(:items_body) { File.read(Rails.root.join("spec/fixtures/integrations/mercado_livre_items.json")) }

  describe "#authenticate" do
    it "returns true when the channel accepts the credentials" do
      stub_request(:get, search_url)
        .with(query: hash_including("limit" => "1"), headers: { "Authorization" => "Bearer APP_USR-token" })
        .to_return(status: 200, body: search_body, headers: { "Content-Type" => "application/json" })

      expect(adapter.authenticate).to eq(true)
    end

    it "raises AuthenticationError on 401" do
      stub_request(:get, search_url)
        .with(query: hash_including("limit" => "1"))
        .to_return(status: 401, body: { message: "invalid_token" }.to_json)

      expect { adapter.authenticate }.to raise_error(Integrations::AuthenticationError)
    end

    it "raises RateLimitError on 429" do
      stub_request(:get, search_url)
        .with(query: hash_including("limit" => "1"))
        .to_return(status: 429, body: { message: "rate limited" }.to_json, headers: { "Retry-After" => "15" })

      expect { adapter.authenticate }.to raise_error(Integrations::RateLimitError) do |error|
        expect(error.retry_after).to eq(15)
      end
    end
  end

  describe "#fetch_products / #normalize_product" do
    before do
      stub_request(:get, search_url)
        .with(query: hash_including("status" => "active"))
        .to_return(status: 200, body: search_body, headers: { "Content-Type" => "application/json" })
      stub_request(:get, items_url)
        .with(query: hash_including("ids" => "MLB111,MLB222"))
        .to_return(status: 200, body: items_body, headers: { "Content-Type" => "application/json" })
    end

    it "fetches both items via the two-step search-then-multiget flow" do
      raws = adapter.fetch_products
      expect(raws.map { |r| r["id"] }).to contain_exactly("MLB111", "MLB222")
    end

    it "normalizes an item using seller_custom_field for the SKU" do
      raw = adapter.fetch_products.find { |r| r["id"] == "MLB111" }

      expect(adapter.normalize_product(raw)).to include(
        external_id:  "MLB111",
        external_sku: "CAM-AZUL-M",
        name:         "Camiseta Azul",
        price:        BigDecimal("59.9"),
        stock_qty:    BigDecimal("20")
      )
    end

    it "falls back to the SELLER_SKU attribute when seller_custom_field is absent" do
      raw = adapter.fetch_products.find { |r| r["id"] == "MLB222" }

      expect(adapter.normalize_product(raw)).to include(external_sku: "BONE-VERM")
    end
  end
end
