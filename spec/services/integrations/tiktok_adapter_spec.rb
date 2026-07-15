require "rails_helper"

# Both the auth/signing contract and the product payload shape are grounded
# against TikTok Shop Partner Center docs (July 2026): 202309+ APIs send the
# access token in `x-tts-access-token`, and Search Products 202309 returns
# skus[] with `id`, `seller_sku` (optional, may be blank) and
# `price.{tax_exclusive_price, sale_price}`.
RSpec.describe Integrations::TiktokAdapter do
  let(:credentials) { { app_key: "key123", app_secret: "secret456", access_token: "tok789", shop_cipher: "GCP_cipher" } }
  let(:adapter) { described_class.new(credentials) }
  let(:search_url) { "https://open-api.tiktokglobalshop.com/product/202309/products/search" }
  let(:fixture_body) { File.read(Rails.root.join("spec/fixtures/integrations/tiktok_products.json")) }

  describe "#authenticate" do
    it "returns true when code is 0 (success envelope)" do
      stub_request(:post, /\A#{Regexp.escape(search_url)}/)
        .to_return(status: 200, body: fixture_body, headers: { "Content-Type" => "application/json" })

      expect(adapter.authenticate).to eq(true)
    end

    it "sends the access token as x-tts-access-token header, not a query param" do
      captured_request = nil

      stub_request(:post, /\A#{Regexp.escape(search_url)}/)
        .with { |request| captured_request = request }
        .to_return(status: 200, body: fixture_body, headers: { "Content-Type" => "application/json" })

      adapter.authenticate

      query = Rack::Utils.parse_query(captured_request.uri.query)
      expect(query).to include("app_key" => "key123")
      expect(query).to include("shop_cipher" => "GCP_cipher")
      expect(query).to include("timestamp", "sign")
      expect(query).not_to include("access_token")
      expect(captured_request.headers["X-Tts-Access-Token"]).to eq("tok789")
    end

    it "excludes access_token from the signature and includes the JSON body" do
      path = "/product/202309/products/search"
      params = { app_key: "key123", timestamp: 1_623_812_664 }
      encoded_body = JSON.generate(page_size: 1)

      signature = adapter.send(:sign, path, params.merge(access_token: "tok789"), encoded_body)

      expect(signature).to eq(adapter.send(:sign, path, params, encoded_body))
      expect(signature).not_to eq(adapter.send(:sign, path, params))
    end

    it "raises AuthenticationError when the body code/message indicate a bad signature or token" do
      stub_request(:post, /\A#{Regexp.escape(search_url)}/)
        .to_return(status: 200, body: { code: 105_002, message: "Invalid access_token" }.to_json, headers: { "Content-Type" => "application/json" })

      expect { adapter.authenticate }.to raise_error(Integrations::AuthenticationError)
    end

    it "raises AuthenticationError on HTTP 401/403 too" do
      stub_request(:post, /\A#{Regexp.escape(search_url)}/)
        .to_return(status: 401, body: { code: 1, message: "Unauthorized" }.to_json)

      expect { adapter.authenticate }.to raise_error(Integrations::AuthenticationError)
    end

    it "raises RateLimitError when the body code/message indicate throttling" do
      stub_request(:post, /\A#{Regexp.escape(search_url)}/)
        .to_return(status: 200, body: { code: 9999, message: "Request frequency exceeds limit" }.to_json, headers: { "Content-Type" => "application/json" })

      expect { adapter.authenticate }.to raise_error(Integrations::RateLimitError)
    end

    it "raises RateLimitError on HTTP 429 too" do
      stub_request(:post, /\A#{Regexp.escape(search_url)}/)
        .to_return(status: 429, body: { code: 1, message: "Too many requests" }.to_json, headers: { "Retry-After" => "5" })

      expect { adapter.authenticate }.to raise_error(Integrations::RateLimitError) do |error|
        expect(error.retry_after).to eq(5)
      end
    end

    it "raises ApiError for any other non-zero code" do
      stub_request(:post, /\A#{Regexp.escape(search_url)}/)
        .to_return(status: 200, body: { code: 42, message: "Something else went wrong" }.to_json, headers: { "Content-Type" => "application/json" })

      expect { adapter.authenticate }.to raise_error(Integrations::ApiError)
    end
  end

  describe "#fetch_products / #normalize_product" do
    before do
      stub_request(:post, /\A#{Regexp.escape(search_url)}/)
        .to_return(status: 200, body: fixture_body, headers: { "Content-Type" => "application/json" })
    end

    it "flattens each product's skus into one raw record per SKU" do
      raws = adapter.fetch_products
      expect(raws.size).to eq(2)
    end

    it "normalizes a sku correctly" do
      raw = adapter.fetch_products.find { |r| r["seller_sku"] == "FONE-BT-X-PRETO" }

      expect(adapter.normalize_product(raw)).to include(
        external_id:  "sku-001",
        external_sku: "FONE-BT-X-PRETO",
        name:         "Fone Bluetooth X",
        price:        BigDecimal("89.90"),
        stock_qty:    BigDecimal("30")
      )
    end

    it "falls back to the TikTok SKU id when seller_sku is blank" do
      raw = adapter.fetch_products.find { |r| r["id"] == "sku-002" }

      expect(adapter.normalize_product(raw)).to include(
        external_id:  "sku-002",
        external_sku: "sku-002",
        stock_qty:    BigDecimal("12")
      )
    end

    it "prefers sale_price over tax_exclusive_price when present" do
      raw = {
        "id" => "sku-003",
        "seller_sku" => "SKU-3",
        "price" => { "currency" => "BRL", "tax_exclusive_price" => "80.00", "sale_price" => "96.00" },
        "inventory" => [],
        "_product_title" => "Produto"
      }

      expect(adapter.normalize_product(raw)[:price]).to eq(BigDecimal("96.00"))
    end
  end

  describe "#fetch_orders_page" do
    let(:orders_url) { "https://open-api.tiktokglobalshop.com/order/202309/orders/search" }
    let(:orders_body) do
      {
        code: 0,
        message: "Success",
        data: {
          orders: [ { id: "576461413038785752", status: "COMPLETED" } ],
          next_page_token: "tok-2",
          total_count: 1
        }
      }.to_json
    end

    it "sends pagination in the query and time filters in the JSON body" do
      captured_request = nil

      stub_request(:post, /\A#{Regexp.escape(orders_url)}/)
        .with { |request| captured_request = request }
        .to_return(status: 200, body: orders_body, headers: { "Content-Type" => "application/json" })

      data = adapter.fetch_orders_page(
        filters: { create_time_ge: 1_623_812_664, create_time_lt: 1_623_899_064 },
        page_token: nil,
        sort_field: "create_time"
      )

      query = Rack::Utils.parse_query(captured_request.uri.query)
      expect(query).to include("page_size" => "50", "sort_field" => "create_time", "sort_order" => "ASC")
      expect(query).to include("shop_cipher" => "GCP_cipher")
      expect(query).not_to include("page_token")
      expect(JSON.parse(captured_request.body)).to eq(
        "create_time_ge" => 1_623_812_664, "create_time_lt" => 1_623_899_064
      )
      expect(data["orders"].size).to eq(1)
      expect(data["next_page_token"]).to eq("tok-2")
    end

    it "raises AuthenticationError with a scope hint on permission errors" do
      stub_request(:post, /\A#{Regexp.escape(orders_url)}/)
        .to_return(
          status: 200,
          body: { code: 105_005, message: "No permission to call this api" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      expect { adapter.fetch_orders_page }.to raise_error(Integrations::AuthenticationError, /escopo/)
    end
  end
end
