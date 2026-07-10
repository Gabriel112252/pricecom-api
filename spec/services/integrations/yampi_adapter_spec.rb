require "rails_helper"

# All assertions here run against the mocked payload in
# spec/fixtures/integrations/yampi_products.json (shape verified against
# docs.yampi.com.br/api-reference on 2026-07-09 — see YampiAdapter's class
# comment). No real Yampi API call is made or verified anywhere in this spec.
RSpec.describe Integrations::YampiAdapter do
  let(:credentials) { { alias: "minha-loja", token: "tok123", secret_key: "sec456" } }
  let(:adapter) { described_class.new(credentials) }
  let(:products_url) { "https://api.dooki.com.br/v2/minha-loja/catalog/products" }
  let(:fixture_body) { File.read(Rails.root.join("spec/fixtures/integrations/yampi_products.json")) }

  describe "#authenticate" do
    it "returns true when the channel accepts the credentials" do
      stub_request(:get, products_url)
        .with(query: hash_including("page" => "1", "per_page" => "1"), headers: { "User-Token" => "tok123", "User-Secret-Key" => "sec456" })
        .to_return(status: 200, body: fixture_body, headers: { "Content-Type" => "application/json" })

      expect(adapter.authenticate).to eq(true)
    end

    it "raises AuthenticationError on 401" do
      stub_request(:get, products_url)
        .with(query: hash_including("page" => "1"))
        .to_return(status: 401, body: { message: "Unauthenticated" }.to_json)

      expect { adapter.authenticate }.to raise_error(Integrations::AuthenticationError)
    end

    it "raises AuthenticationError on 403" do
      stub_request(:get, products_url)
        .with(query: hash_including("page" => "1"))
        .to_return(status: 403, body: { message: "Forbidden" }.to_json)

      expect { adapter.authenticate }.to raise_error(Integrations::AuthenticationError)
    end

    it "raises RateLimitError on 429 and captures Retry-After" do
      stub_request(:get, products_url)
        .with(query: hash_including("page" => "1"))
        .to_return(status: 429, body: { message: "Too Many Requests" }.to_json, headers: { "Retry-After" => "30" })

      expect { adapter.authenticate }.to raise_error(Integrations::RateLimitError) do |error|
        expect(error.retry_after).to eq(30)
      end
    end
  end

  describe "#fetch_products / #normalize_product" do
    before do
      stub_request(:get, products_url)
        .with(query: hash_including("include" => "skus"))
        .to_return(status: 200, body: fixture_body, headers: { "Content-Type" => "application/json" })
    end

    it "flattens each product's SKUs into one raw record per sellable SKU" do
      raws = adapter.fetch_products
      expect(raws.size).to eq(3) # 2 variations on the shirt + 1 on the simple mug
    end

    it "normalizes a variation SKU correctly" do
      raw = adapter.fetch_products.find { |r| r["sku"] == "CAM-001-P-AZUL" }

      expect(adapter.normalize_product(raw)).to include(
        external_id:  "987001",
        external_sku: "CAM-001-P-AZUL",
        name:         "Camiseta Premium",
        price:        BigDecimal("79.9"),
        stock_qty:    BigDecimal("15")
      )
    end

    it "normalizes a simple (non-variation) product's single SKU correctly" do
      raw = adapter.fetch_products.find { |r| r["sku"] == "CAN-001" }

      expect(adapter.normalize_product(raw)).to include(
        external_id:  "987010",
        external_sku: "CAN-001",
        name:         "Caneca Simples",
        price:        BigDecimal("29.9"),
        stock_qty:    BigDecimal("10")
      )
    end

    it "paginates until total_pages is reached" do
      page1 = JSON.parse(fixture_body)
      page1["meta"]["pagination"] = page1["meta"]["pagination"].merge("current_page" => 1, "total_pages" => 2)
      page2 = { "data" => [ { "id" => 99, "sku" => "EXTRA-1", "name" => "Extra", "total_in_stock" => 3 } ],
                "meta" => { "pagination" => { "current_page" => 2, "total_pages" => 2 } } }

      json_headers = { "Content-Type" => "application/json" }
      stub_request(:get, products_url)
        .with(query: hash_including("page" => "1"))
        .to_return(status: 200, body: page1.to_json, headers: json_headers)
      stub_request(:get, products_url)
        .with(query: hash_including("page" => "2"))
        .to_return(status: 200, body: page2.to_json, headers: json_headers)

      raws = adapter.fetch_products
      expect(raws.map { |r| r["sku"] }).to include("CAM-001-P-AZUL", "EXTRA-1")
    end
  end

  describe "#fetch_orders" do
    let(:orders_url) { "https://api.dooki.com.br/v2/minha-loja/orders" }
    let(:orders_fixture) { File.read(Rails.root.join("spec/fixtures/integrations/yampi_orders.json")) }

    it "sends the created_at date filter for the requested window" do
      stub_request(:get, orders_url)
        .with(query: hash_including("date" => "created_at:2026-05-16|2026-06-15"))
        .to_return(status: 200, body: orders_fixture, headers: { "Content-Type" => "application/json" })

      orders = adapter.fetch_orders(since: Time.zone.parse("2026-05-16"), until_date: Time.zone.parse("2026-06-15"))

      expect(orders.map { |o| o["id"] }).to eq([ 1000001, 1000002 ])
    end

    it "paginates until total_pages is reached, same as fetch_products" do
      page1 = JSON.parse(orders_fixture)
      page1["meta"]["pagination"] = page1["meta"]["pagination"].merge("current_page" => 1, "total_pages" => 2)
      page2 = { "data" => [ { "id" => 1000003, "number" => 555003 } ],
                "meta" => { "pagination" => { "current_page" => 2, "total_pages" => 2 } } }
      json_headers = { "Content-Type" => "application/json" }

      stub_request(:get, orders_url).with(query: hash_including("page" => "1")).to_return(status: 200, body: page1.to_json, headers: json_headers)
      stub_request(:get, orders_url).with(query: hash_including("page" => "2")).to_return(status: 200, body: page2.to_json, headers: json_headers)

      orders = adapter.fetch_orders(since: 30.days.ago)

      expect(orders.map { |o| o["id"] }).to include(1000001, 1000002, 1000003)
    end

    it "retries transparently on a 429 and succeeds once the rate limit clears" do
      call_count = 0
      stub_request(:get, orders_url).with(query: hash_including("page" => "1")).to_return do
        call_count += 1
        if call_count == 1
          { status: 429, body: { message: "Too Many Requests" }.to_json, headers: { "Retry-After" => "0" } }
        else
          { status: 200, body: orders_fixture, headers: { "Content-Type" => "application/json" } }
        end
      end
      allow(adapter).to receive(:sleep)

      orders = adapter.fetch_orders(since: 30.days.ago)

      expect(call_count).to eq(2)
      expect(orders.map { |o| o["id"] }).to eq([ 1000001, 1000002 ])
    end

    it "gives up and raises after exceeding the retry budget" do
      stub_request(:get, orders_url).with(query: hash_including("page" => "1"))
        .to_return(status: 429, body: { message: "Too Many Requests" }.to_json, headers: { "Retry-After" => "0" })
      allow(adapter).to receive(:sleep)

      expect { adapter.fetch_orders(since: 30.days.ago) }.to raise_error(Integrations::RateLimitError)
    end
  end
end
