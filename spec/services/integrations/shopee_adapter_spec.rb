require "rails_helper"

# ⚠️ These assertions prove the adapter parses/handles the v2 shapes it
# assumes — the money/pagination fields still need confirmation against a
# real sandbox payload (Fase 2/4 gates). No real Shopee call is made here.
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

  it "delegates the sign to ShopeeAuthService#shop_sign (single signature source)" do
    stub_request(:get, list_url).to_return(status: 200, body: list_body, headers: { "Content-Type" => "application/json" })
    allow_any_instance_of(Integrations::ShopeeAuthService).to receive(:shop_sign).and_return("delegated-sign")

    adapter.authenticate

    expect(WebMock).to have_requested(:get, list_url)
      .with(query: hash_including("sign" => "delegated-sign"))
  end

  it "uses the sandbox base URL when environment=sandbox" do
    sandbox_adapter = described_class.new(credentials.merge(environment: "sandbox"))
    stub = stub_request(:get, %r{\Ahttps://partner\.test-stable\.shopeemobile\.com/api/v2/product/get_item_list})
      .to_return(status: 200, body: list_body, headers: { "Content-Type" => "application/json" })

    sandbox_adapter.authenticate

    expect(stub).to have_been_requested
  end

  describe "variations (has_model)" do
    let(:model_url) { %r{\Ahttps://partner\.shopeemobile\.com/api/v2/product/get_model_list} }
    let(:info_with_model) do
      {
        error: "", message: "",
        response: {
          item_list: [
            {
              item_id: 1001,
              item_sku: "PAI-1",
              item_name: "Produto Variado",
              has_model: true
            }
          ]
        }
      }.to_json
    end
    let(:model_body) do
      {
        error: "", message: "",
        response: {
          tier_variation: [
            { name: "Tamanho", option_list: [ { option: "30ml" }, { option: "60ml" } ] }
          ],
          model: [
            {
              model_id: 9001,
              model_sku: "SKU-30",
              tier_index: [ 0 ],
              price_info: [ { current_price: 45.5 } ],
              stock_info_v2: { summary_info: { total_available_stock: 7 } }
            },
            {
              model_id: 9002,
              model_sku: "",
              tier_index: [ 1 ],
              price_info: [ { current_price: 79.9 } ],
              stock_info_v2: { summary_info: { total_available_stock: 3 } }
            }
          ]
        }
      }.to_json
    end

    before do
      stub_request(:get, list_url).to_return(
        status: 200,
        body: { error: "", message: "", response: { item: [ { item_id: 1001 } ], has_next_page: false } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
      stub_request(:get, info_url).to_return(status: 200, body: info_with_model, headers: { "Content-Type" => "application/json" })
      stub_request(:get, model_url)
        .with(query: hash_including("item_id" => "1001"))
        .to_return(status: 200, body: model_body, headers: { "Content-Type" => "application/json" })
    end

    it "expands each model into its own purchasable-SKU row" do
      raws = adapter.fetch_products

      expect(raws.size).to eq(2)
      expect(raws.map { |r| r["model_id"] }).to contain_exactly(9001, 9002)
    end

    it "normalizes a model with parent name, variation label and model_id fallback for blank SKU" do
      raws = adapter.fetch_products

      first = adapter.normalize_product(raws.find { |r| r["model_id"] == 9001 })
      expect(first).to include(
        external_id: "9001",
        external_sku: "SKU-30",
        name: "Produto Variado (30ml)",
        price: BigDecimal("45.5"),
        stock_qty: BigDecimal("7"),
        external_product_id: "1001"
      )

      second = adapter.normalize_product(raws.find { |r| r["model_id"] == 9002 })
      expect(second[:external_sku]).to eq("9002")
      expect(second[:name]).to eq("Produto Variado (60ml)")
    end
  end

  describe "#fetch_orders_page" do
    let(:order_list_url) { %r{\Ahttps://partner\.shopeemobile\.com/api/v2/order/get_order_list} }

    it "requests the window with cursor pagination params and returns the response hash" do
      stub_request(:get, order_list_url)
        .with(query: hash_including(
          "time_range_field" => "create_time",
          "time_from" => "1000",
          "time_to" => "2000",
          "cursor" => "",
          "page_size" => "50"
        ))
        .to_return(
          status: 200,
          body: {
            error: "", message: "",
            response: { order_list: [ { order_sn: "SN-1" } ], more: true, next_cursor: "abc" }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      page = adapter.fetch_orders_page(time_range_field: "create_time", time_from: 1000, time_to: 2000)

      expect(page["order_list"].first["order_sn"]).to eq("SN-1")
      expect(page["more"]).to be(true)
      expect(page["next_cursor"]).to eq("abc")
    end

    it "refuses windows above the documented 15-day maximum" do
      expect {
        adapter.fetch_orders_page(time_range_field: "create_time", time_from: 0, time_to: 16.days.to_i)
      }.to raise_error(ArgumentError, /15 dias/)
    end
  end

  describe "#fetch_order_details" do
    let(:order_detail_url) { %r{\Ahttps://partner\.shopeemobile\.com/api/v2/order/get_order_detail} }

    it "requests the batch with the money/item optional fields" do
      stub_request(:get, order_detail_url)
        .with(query: hash_including("order_sn_list" => "SN-1,SN-2"))
        .to_return(
          status: 200,
          body: { error: "", message: "", response: { order_list: [ { order_sn: "SN-1" }, { order_sn: "SN-2" } ] } }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      details = adapter.fetch_order_details(%w[SN-1 SN-2])

      expect(details.map { |d| d["order_sn"] }).to eq(%w[SN-1 SN-2])
      expect(WebMock).to have_requested(:get, order_detail_url)
        .with(query: hash_including("response_optional_fields" => /item_list/))
    end

    it "rejects batches above 50 order_sn" do
      expect { adapter.fetch_order_details((1..51).map { |i| "SN-#{i}" }) }
        .to raise_error(ArgumentError, /50/)
    end
  end

  describe "#fetch_escrow_detail" do
    it "returns the escrow response hash for one order_sn" do
      stub_request(:get, %r{\Ahttps://partner\.shopeemobile\.com/api/v2/payment/get_escrow_detail})
        .with(query: hash_including("order_sn" => "SN-1"))
        .to_return(
          status: 200,
          body: { error: "", message: "", response: { order_sn: "SN-1", order_income: { escrow_amount: 80.0 } } }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      escrow = adapter.fetch_escrow_detail("SN-1")

      expect(escrow["order_sn"]).to eq("SN-1")
      expect(escrow.dig("order_income", "escrow_amount")).to eq(80.0)
    end
  end

  describe "#update_stock" do
    it "refuses explicitly instead of guessing the unvalidated write schema" do
      expect { adapter.update_stock(external_id: "9001", quantity: 5) }
        .to raise_error(Integrations::UnsupportedOperationError)
    end
  end
end
