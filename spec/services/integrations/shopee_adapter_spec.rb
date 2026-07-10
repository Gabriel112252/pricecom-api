require "rails_helper"

# ⚠️ See ShopeeAdapter's class comment: the real Shopee docs couldn't be
# fetched in this environment, so these assertions only prove the adapter
# parses/handles the shape it itself assumes — not that the design matches
# Shopee's actual API. No real Shopee call is made anywhere in this spec.
RSpec.describe Integrations::ShopeeAdapter do
  let(:credentials) { { shop_id: "555", partner_id: "111", partner_key: "secretkey", access_token: "tok" } }
  let(:adapter) { described_class.new(credentials) }
  # Every request is signed with a dynamic timestamp/sign query param, so
  # stubs match the URL prefix rather than an exact query string.
  let(:list_url) { %r{\Ahttps://partner\.shopeemobile\.com/api/v2/product/get_item_list} }
  let(:info_url) { %r{\Ahttps://partner\.shopeemobile\.com/api/v2/product/get_item_base_info} }
  let(:list_body) { File.read(Rails.root.join("spec/fixtures/integrations/shopee_item_list.json")) }
  let(:info_body) { File.read(Rails.root.join("spec/fixtures/integrations/shopee_item_base_info.json")) }

  describe "#authenticate" do
    it "returns true when the response envelope has no error" do
      stub_request(:get, list_url).to_return(status: 200, body: list_body, headers: { "Content-Type" => "application/json" })

      expect(adapter.authenticate).to eq(true)
    end

    it "raises AuthenticationError when the body error/message indicate a bad sign or token" do
      stub_request(:get, list_url)
        .to_return(status: 200, body: { error: "error_auth", message: "Invalid access_token" }.to_json, headers: { "Content-Type" => "application/json" })

      expect { adapter.authenticate }.to raise_error(Integrations::AuthenticationError)
    end

    it "raises AuthenticationError on HTTP 401/403 too" do
      stub_request(:get, list_url).to_return(status: 403, body: { error: "1", message: "Forbidden" }.to_json)

      expect { adapter.authenticate }.to raise_error(Integrations::AuthenticationError)
    end

    it "raises RateLimitError when the body error/message indicate throttling" do
      stub_request(:get, list_url)
        .to_return(status: 200, body: { error: "error_too_many_requests", message: "Request frequency exceeds the limit" }.to_json, headers: { "Content-Type" => "application/json" })

      expect { adapter.authenticate }.to raise_error(Integrations::RateLimitError)
    end

    it "raises RateLimitError on HTTP 429 too" do
      stub_request(:get, list_url).to_return(status: 429, body: { error: "1", message: "Too many requests" }.to_json, headers: { "Retry-After" => "8" })

      expect { adapter.authenticate }.to raise_error(Integrations::RateLimitError) do |error|
        expect(error.retry_after).to eq(8)
      end
    end

    it "raises ApiError for any other non-blank error code" do
      stub_request(:get, list_url)
        .to_return(status: 200, body: { error: "error_param", message: "Invalid parameter" }.to_json, headers: { "Content-Type" => "application/json" })

      expect { adapter.authenticate }.to raise_error(Integrations::ApiError)
    end
  end

  describe "#fetch_products / #normalize_product" do
    before do
      stub_request(:get, list_url).to_return(status: 200, body: list_body, headers: { "Content-Type" => "application/json" })
      stub_request(:get, info_url)
        .with(query: hash_including("item_id_list" => "1001,1002"))
        .to_return(status: 200, body: info_body, headers: { "Content-Type" => "application/json" })
    end

    it "fetches both items via the item-list-then-base-info flow" do
      raws = adapter.fetch_products
      expect(raws.map { |r| r["item_id"] }).to contain_exactly(1001, 1002)
    end

    it "normalizes an item correctly" do
      raw = adapter.fetch_products.find { |r| r["item_id"] == 1001 }

      expect(adapter.normalize_product(raw)).to include(
        external_id:  "1001",
        external_sku: "SHOPEE-SKU-1",
        name:         "Produto Shopee 1",
        price:        BigDecimal("45.5"),
        stock_qty:    BigDecimal("12")
      )
    end
  end

  it "signs requests with partner_id/timestamp/access_token/shop_id/sign query params" do
    stub = stub_request(:get, list_url)
      .with(query: hash_including("partner_id" => "111", "shop_id" => "555", "access_token" => "tok"))
      .to_return(status: 200, body: list_body, headers: { "Content-Type" => "application/json" })

    adapter.authenticate

    expect(stub).to have_been_requested
  end
end
