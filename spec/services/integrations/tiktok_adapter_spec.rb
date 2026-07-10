require "rails_helper"

# ⚠️ Unlike the Yampi and Shopify specs, this one is NOT grounded against a
# confirmed copy of TikTok Shop's real API docs (see TiktokAdapter's class
# comment — their docs are a JS-rendered SPA that couldn't be fetched here).
# These assertions only prove the adapter parses/handles the shape it
# itself assumes, and that the sign/error-classification logic behaves as
# designed — not that the design matches TikTok's actual API.
RSpec.describe Integrations::TiktokAdapter do
  let(:credentials) { { app_key: "key123", app_secret: "secret456", access_token: "tok789" } }
  let(:adapter) { described_class.new(credentials) }
  let(:search_url) { "https://open-api.tiktokglobalshop.com/product/202309/products/search" }
  let(:fixture_body) { File.read(Rails.root.join("spec/fixtures/integrations/tiktok_products.json")) }

  describe "#authenticate" do
    it "returns true when code is 0 (success envelope)" do
      stub_request(:post, /\A#{Regexp.escape(search_url)}/)
        .to_return(status: 200, body: fixture_body, headers: { "Content-Type" => "application/json" })

      expect(adapter.authenticate).to eq(true)
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
  end
end
