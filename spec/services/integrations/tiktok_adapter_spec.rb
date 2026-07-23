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
        external_id:         "sku-001",
        external_sku:        "FONE-BT-X-PRETO",
        name:                "Fone Bluetooth X",
        price:                BigDecimal("89.90"),
        stock_qty:            BigDecimal("30"),
        external_product_id: "1729999999"
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

    it "does not leak the internal _parent_product_id key into the stored raw payload" do
      raw = adapter.fetch_products.find { |r| r["seller_sku"] == "FONE-BT-X-PRETO" }

      expect(adapter.normalize_product(raw)[:raw]).not_to have_key("_parent_product_id")
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

  describe "#fetch_order_details" do
    let(:detail_url) { "https://open-api.tiktokglobalshop.com/order/202309/orders" }
    let(:detail_body) do
      {
        code: 0,
        message: "Success",
        data: { orders: [ { id: "576461413038785752", status: "AWAITING_SHIPMENT" } ] }
      }.to_json
    end

    it "GETs the ids as a comma-separated query param, signed and shop-scoped, with no body" do
      captured_request = nil

      stub_request(:get, /\A#{Regexp.escape(detail_url)}/)
        .with { |request| captured_request = request }
        .to_return(status: 200, body: detail_body, headers: { "Content-Type" => "application/json" })

      orders = adapter.fetch_order_details([ "576461413038785752", 576_461_413_038_785_753 ])

      query = Rack::Utils.parse_query(captured_request.uri.query)
      expect(query).to include("ids" => "576461413038785752,576461413038785753")
      expect(query).to include("shop_cipher" => "GCP_cipher")
      expect(query).to include("timestamp", "sign")
      expect(captured_request.headers["X-Tts-Access-Token"]).to eq("tok789")
      expect(orders.first).to include("id" => "576461413038785752", "status" => "AWAITING_SHIPMENT")
    end

    it "returns [] without calling the API when there are no ids" do
      expect(adapter.fetch_order_details([])).to eq([])
    end

    it "rejects more than ORDER_DETAIL_MAX_IDS ids per call" do
      ids = Array.new(described_class::ORDER_DETAIL_MAX_IDS + 1) { |i| i.to_s }

      expect { adapter.fetch_order_details(ids) }.to raise_error(ArgumentError)
    end
  end

  describe "#fetch_order_statement_transactions" do
    let(:statement_url) { "https://open-api.tiktokglobalshop.com/finance/202501/orders/584933315891857248/statement_transactions" }
    let(:statement_fixture) { File.read(Rails.root.join("spec/fixtures/integrations/tiktok_order_statement_transactions.json")) }

    it "GETs the order statement with the explicit shop_cipher and returns the complete envelope" do
      captured_request = nil

      stub_request(:get, /\A#{Regexp.escape(statement_url)}/)
        .with { |request| captured_request = request }
        .to_return(status: 200, body: statement_fixture, headers: { "Content-Type" => "application/json" })

      result = adapter.fetch_order_statement_transactions("584933315891857248")

      query = Rack::Utils.parse_query(captured_request.uri.query)
      expect(query).to include("shop_cipher" => "GCP_cipher")
      expect(query).to include("timestamp", "sign")
      expect(captured_request.headers["X-Tts-Access-Token"]).to eq("tok789")
      expect(result).to eq(JSON.parse(statement_fixture))
    end

    it "strips whitespace from a numeric order_id before building the path" do
      captured_request = nil

      stub_request(:get, /\A#{Regexp.escape(statement_url)}/)
        .with { |request| captured_request = request }
        .to_return(status: 200, body: statement_fixture, headers: { "Content-Type" => "application/json" })

      adapter.fetch_order_statement_transactions(" 584933315891857248 ")

      expect(captured_request.uri.path).to eq("/finance/202501/orders/584933315891857248/statement_transactions")
    end

    it "rejects a blank order_id before making an HTTP request" do
      expect { adapter.fetch_order_statement_transactions(" ") }
        .to raise_error(ArgumentError, /order_id inválido/)
    end

    it "rejects a non-numeric order_id before making an HTTP request" do
      expect { adapter.fetch_order_statement_transactions("584933315891857248x") }
        .to raise_error(ArgumentError, /order_id inválido/)
    end

    it "raises an authentication error when shop_cipher is absent without exposing credentials" do
      adapter_without_shop_cipher = described_class.new(credentials.merge(shop_cipher: " "))

      expect { adapter_without_shop_cipher.fetch_order_statement_transactions("584933315891857248") }
        .to raise_error(Integrations::AuthenticationError) { |error|
          expect(error.message).to include("reautorize a integração TikTok Shop")
          expect(error.message).not_to include("tok789", "secret456", "GCP_cipher")
        }
    end
  end

  describe "#fetch_financial_statements" do
    let(:statements_url) { "https://open-api.tiktokglobalshop.com/finance/202309/statements" }

    it "paginates statements, sends the shop cipher and preserves raw pages" do
      stub_request(:get, /\A#{Regexp.escape(statements_url)}/)
        .to_return(
          { status: 200, body: { code: 0, data: { statements: [ { "id" => "s-1", "statement_time" => 1 } ], next_page_token: "next" } }.to_json },
          { status: 200, body: { code: 0, data: { statements: [ { "id" => "s-2", "statement_time" => 2 } ], next_page_token: "" } }.to_json }
        )

      statements = adapter.fetch_financial_statements(
        statement_time_ge: 1_751_000_000,
        statement_time_lt: 1_751_086_400,
        payment_status: "PAID"
      )

      expect(statements.map { |statement| statement["id"] }).to eq(%w[s-1 s-2])
      expect(statements.raw_pages.size).to eq(2)
      expect(WebMock).to have_requested(:get, /\A#{Regexp.escape(statements_url)}/)
        .with(query: hash_including("shop_cipher" => "GCP_cipher", "payment_status" => "PAID"))
        .twice
    end

    it "raises for an invalid finance page and for HTTP 500" do
      stub_request(:get, /\A#{Regexp.escape(statements_url)}/)
        .to_return(status: 200, body: { code: 0, data: { statements: {} } }.to_json)
      expect {
        adapter.fetch_financial_statements(statement_time_ge: 1, statement_time_lt: 2)
      }.to raise_error(Integrations::ApiError, /statements inválido/)

      stub_request(:get, /\A#{Regexp.escape(statements_url)}/)
        .to_return(status: 500, body: "server error")
      expect {
        adapter.fetch_financial_statements(statement_time_ge: 1, statement_time_lt: 2)
      }.to raise_error(Integrations::ApiError, /HTTP|resposta inesperada/)
    end
  end

  describe "#fetch_statement_transactions" do
    let(:statement_transactions_url) do
      "https://open-api.tiktokglobalshop.com/finance/202501/statements/s-1/statement_transactions"
    end

    it "paginates statement transactions and sends token and shop cipher" do
      stub_request(:get, /\A#{Regexp.escape(statement_transactions_url)}/)
        .to_return(
          { status: 200, body: { code: 0, data: { transactions: [ { "id" => "tx-1" } ], next_page_token: "next" } }.to_json },
          { status: 200, body: { code: 0, data: { transactions: [ { "id" => "tx-2" } ], next_page_token: "" } }.to_json }
        )

      transactions = adapter.fetch_statement_transactions(statement_id: "s-1")

      expect(transactions.map { |transaction| transaction["id"] }).to eq(%w[tx-1 tx-2])
      expect(transactions.raw_pages.size).to eq(2)
      expect(WebMock).to have_requested(:get, /\A#{Regexp.escape(statement_transactions_url)}/)
        .with(query: hash_including("shop_cipher" => "GCP_cipher"))
        .twice
    end

    it "raises RateLimitError on HTTP 429" do
      stub_request(:get, /\A#{Regexp.escape(statement_transactions_url)}/)
        .to_return(status: 429, body: { message: "too many requests" }.to_json, headers: { "Retry-After" => "7" })

      expect { adapter.fetch_statement_transactions(statement_id: "s-1") }
        .to raise_error(Integrations::RateLimitError) { |error| expect(error.retry_after).to eq(7) }
    end
  end

  describe "#fetch_warehouses" do
    let(:warehouses_url) { "https://open-api.tiktokglobalshop.com/logistics/202309/warehouses" }
    let(:warehouses_fixture) { File.read(Rails.root.join("spec/fixtures/integrations/tiktok_warehouses.json")) }

    it "returns the normalized warehouse list" do
      stub_request(:get, /\A#{Regexp.escape(warehouses_url)}/)
        .to_return(status: 200, body: warehouses_fixture, headers: { "Content-Type" => "application/json" })

      warehouses = adapter.fetch_warehouses

      expect(warehouses).to eq([
        { id: "7000714532876273410", name: "Guangzhou", effect_status: "ENABLED", type: "SALES_WAREHOUSE", is_default: true }
      ])
    end
  end

  describe "#update_stock" do
    let(:warehouses_url) { "https://open-api.tiktokglobalshop.com/logistics/202309/warehouses" }
    let(:warehouses_fixture) { File.read(Rails.root.join("spec/fixtures/integrations/tiktok_warehouses.json")) }
    let(:inventory_update_url) { "https://open-api.tiktokglobalshop.com/product/202309/products/prod-1/inventory/update" }

    def stub_single_warehouse
      stub_request(:get, /\A#{Regexp.escape(warehouses_url)}/)
        .to_return(status: 200, body: warehouses_fixture, headers: { "Content-Type" => "application/json" })
    end

    def stub_warehouses(list)
      stub_request(:get, /\A#{Regexp.escape(warehouses_url)}/)
        .to_return(status: 200, body: { code: 0, data: { warehouses: list } }.to_json, headers: { "Content-Type" => "application/json" })
    end

    it "sends only id/warehouse_id/quantity (no backorder_quantity/handling_time) and returns the response" do
      stub_single_warehouse
      stub_request(:post, /\A#{Regexp.escape(inventory_update_url)}/)
        .with(body: { skus: [ { id: "sku-001", inventory: [ { warehouse_id: "7000714532876273410", quantity: 42 } ] } ] }.to_json)
        .to_return(status: 200, body: { code: 0, message: "Success", data: {} }.to_json, headers: { "Content-Type" => "application/json" })

      result = adapter.update_stock(external_id: "sku-001", quantity: 42, product_id: "prod-1")

      expect(result["code"]).to eq(0)
      expect(WebMock).to have_requested(:post, /\A#{Regexp.escape(inventory_update_url)}/)
        .with(body: { skus: [ { id: "sku-001", inventory: [ { warehouse_id: "7000714532876273410", quantity: 42 } ] } ] }.to_json)
    end

    it "memoizes the resolved warehouse across multiple writes in the same adapter instance" do
      stub_single_warehouse
      stub_request(:post, /\A#{Regexp.escape(inventory_update_url)}/)
        .to_return(status: 200, body: { code: 0, data: {} }.to_json, headers: { "Content-Type" => "application/json" })

      adapter.update_stock(external_id: "sku-001", quantity: 1, product_id: "prod-1")
      adapter.update_stock(external_id: "sku-002", quantity: 2, product_id: "prod-1")

      expect(WebMock).to have_requested(:get, /\A#{Regexp.escape(warehouses_url)}/).once
    end

    it "raises ArgumentError when product_id is missing, without making any HTTP call" do
      expect { adapter.update_stock(external_id: "sku-001", quantity: 42, product_id: nil) }
        .to raise_error(ArgumentError, /product_id/)

      expect(WebMock).not_to have_requested(:any, /tiktokglobalshop\.com/)
    end

    it "raises ApiError instead of guessing when there are zero enabled sales warehouses" do
      stub_warehouses([])

      expect { adapter.update_stock(external_id: "sku-001", quantity: 42, product_id: "prod-1") }
        .to raise_error(Integrations::ApiError, /found 0/)
    end

    it "raises ApiError instead of guessing when multiple warehouses exist with no single is_default" do
      stub_warehouses([
        { "id" => "w1", "effect_status" => "ENABLED", "type" => "SALES_WAREHOUSE", "is_default" => false },
        { "id" => "w2", "effect_status" => "ENABLED", "type" => "SALES_WAREHOUSE", "is_default" => false }
      ])

      expect { adapter.update_stock(external_id: "sku-001", quantity: 42, product_id: "prod-1") }
        .to raise_error(Integrations::ApiError, /found 2/)
    end

    it "resolves the single warehouse marked is_default when more than one enabled sales warehouse exists" do
      stub_warehouses([
        { "id" => "w1", "effect_status" => "ENABLED", "type" => "SALES_WAREHOUSE", "is_default" => true },
        { "id" => "w2", "effect_status" => "ENABLED", "type" => "SALES_WAREHOUSE", "is_default" => false }
      ])
      stub_request(:post, /\A#{Regexp.escape(inventory_update_url)}/)
        .with(body: { skus: [ { id: "sku-001", inventory: [ { warehouse_id: "w1", quantity: 42 } ] } ] }.to_json)
        .to_return(status: 200, body: { code: 0, data: {} }.to_json, headers: { "Content-Type" => "application/json" })

      adapter.update_stock(external_id: "sku-001", quantity: 42, product_id: "prod-1")

      expect(WebMock).to have_requested(:post, /\A#{Regexp.escape(inventory_update_url)}/)
        .with(body: { skus: [ { id: "sku-001", inventory: [ { warehouse_id: "w1", quantity: 42 } ] } ] }.to_json)
    end

    it "excludes disabled and non-sales warehouses before picking one" do
      stub_warehouses([
        { "id" => "w1", "effect_status" => "DISABLED", "type" => "SALES_WAREHOUSE", "is_default" => true },
        { "id" => "w2", "effect_status" => "ENABLED", "type" => "RETURN_WAREHOUSE", "is_default" => false },
        { "id" => "w3", "effect_status" => "ENABLED", "type" => "SALES_WAREHOUSE", "is_default" => false }
      ])
      stub_request(:post, /\A#{Regexp.escape(inventory_update_url)}/)
        .with(body: { skus: [ { id: "sku-001", inventory: [ { warehouse_id: "w3", quantity: 42 } ] } ] }.to_json)
        .to_return(status: 200, body: { code: 0, data: {} }.to_json, headers: { "Content-Type" => "application/json" })

      adapter.update_stock(external_id: "sku-001", quantity: 42, product_id: "prod-1")

      expect(WebMock).to have_requested(:post, /\A#{Regexp.escape(inventory_update_url)}/)
        .with(body: { skus: [ { id: "sku-001", inventory: [ { warehouse_id: "w3", quantity: 42 } ] } ] }.to_json)
    end

    it "raises AuthenticationError on a 105xxx code from the inventory update call" do
      stub_single_warehouse
      stub_request(:post, /\A#{Regexp.escape(inventory_update_url)}/)
        .to_return(status: 200, body: { code: 105001, message: "Invalid access token" }.to_json, headers: { "Content-Type" => "application/json" })

      expect { adapter.update_stock(external_id: "sku-001", quantity: 42, product_id: "prod-1") }
        .to raise_error(Integrations::AuthenticationError)
    end

    it "raises RateLimitError on a rate-limit-shaped message from the inventory update call" do
      stub_single_warehouse
      stub_request(:post, /\A#{Regexp.escape(inventory_update_url)}/)
        .to_return(status: 200, body: { code: 99999, message: "Too many requests, rate limit exceeded" }.to_json, headers: { "Content-Type" => "application/json" })

      expect { adapter.update_stock(external_id: "sku-001", quantity: 42, product_id: "prod-1") }
        .to raise_error(Integrations::RateLimitError)
    end

    it "raises ApiError for any other non-zero code" do
      stub_single_warehouse
      stub_request(:post, /\A#{Regexp.escape(inventory_update_url)}/)
        .to_return(status: 200, body: { code: 42, message: "Something else went wrong" }.to_json, headers: { "Content-Type" => "application/json" })

      expect { adapter.update_stock(external_id: "sku-001", quantity: 42, product_id: "prod-1") }
        .to raise_error(Integrations::ApiError)
    end
  end
end
