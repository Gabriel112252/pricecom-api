require "rails_helper"

# Endpoint paths and auth flow (POST user/signin/local -> Bearer +
# Origin/FilePath headers) are verified against the tenant's real idworks
# Swagger spec (swagger.idworks.com.br) as of 2026-07-10. The /sku sku-code
# field name is NOT from that spec — IDSkuCompany was confirmed against
# real production data on 2026-07-21 after the Swagger-guessed "Sku" field
# turned out not to exist on the real payload at all (see
# IdworksAdapter's class comment and #normalize_product). /orders field
# names (Order/IDOrder/ValueShipping/etc.) are still only Swagger-sourced,
# unconfirmed against a real payload — same class of risk that just bit
# the sku field, not yet checked.
RSpec.describe Integrations::IdworksAdapter do
  let(:credentials) { { base_url: "https://cliente.idworks.com.br/1.0", email: "user@hidrabene.com", password: "secret" } }
  let(:adapter) { described_class.new(credentials) }
  let(:signin_url) { "https://cliente.idworks.com.br/1.0/user/signin/local" }
  let(:sku_url)    { "https://cliente.idworks.com.br/1.0/sku" }
  let(:orders_url) { "https://cliente.idworks.com.br/1.0/orders" }
  let(:signin_fixture) { File.read(Rails.root.join("spec/fixtures/integrations/idworks_signin.json")) }
  let(:sku_fixture)    { File.read(Rails.root.join("spec/fixtures/integrations/idworks_sku_list.json")) }
  let(:orders_fixture) { File.read(Rails.root.join("spec/fixtures/integrations/idworks_orders_list.json")) }

  def stub_signin(status: 200)
    stub_request(:post, signin_url)
      .with(
        headers: { "Origin" => "https://erp-www.idworks.com.br", "Filepath" => "" },
        body: { email: "user@hidrabene.com", password: "secret" }.to_json
      )
      .to_return(status: status, body: status == 200 ? signin_fixture : { message: "Invalid credentials" }.to_json,
                 headers: { "Content-Type" => "application/json" })
  end

  describe "#authenticate" do
    it "signs in via user/signin/local and returns true" do
      stub_signin

      expect(adapter.authenticate).to eq(true)
    end

    it "raises AuthenticationError when idworks rejects the credentials" do
      stub_signin(status: 401)

      expect { adapter.authenticate }.to raise_error(Integrations::AuthenticationError)
    end
  end

  describe "#fetch_products" do
    before do
      stub_signin
      # idworks' Page param is 0-indexed — confirmed against production
      # 2026-07-21 (Page=0 returned real skus, Page=1 came back empty).
      # Starting the loop at Page=1 used to skip this entire first page
      # silently (200 OK, empty array) on every tenant.
      stub_request(:get, sku_url)
        .with(query: hash_including("Page" => "0"), headers: { "Authorization" => "Bearer #{JSON.parse(signin_fixture)['token']}", "Origin" => "https://erp-www.idworks.com.br" })
        .to_return(status: 200, body: sku_fixture, headers: { "Content-Type" => "application/json" })
      stub_request(:get, sku_url).with(query: hash_including("Page" => "1"))
        .to_return(status: 200, body: { "Data" => [] }.to_json, headers: { "Content-Type" => "application/json" })
    end

    it "requests the first page as Page=0, not Page=1" do
      adapter.fetch_products
      expect(WebMock).to have_requested(:get, sku_url).with(query: hash_including("Page" => "0"))
    end

    it "signs in first, then returns sku/cost_last_purchase/cost_average per product" do
      raws = adapter.fetch_products

      expect(raws).to include(
        hash_including(idworks_id: "12345", sku: "CAM-001-P-AZUL", cost_last_purchase: BigDecimal("60.00"), cost_average: BigDecimal("58.50")),
        hash_including(idworks_id: "12346", sku: "CAN-001", cost_last_purchase: nil, cost_average: BigDecimal("11.20"))
      )
    end

    it "extracts the stock fields per product, preserving a negative QtyAvailable as-is (real overselling signal, not clamped)" do
      raws = adapter.fetch_products
      camiseta = raws.find { |r| r[:sku] == "CAM-001-P-AZUL" }
      caneca   = raws.find { |r| r[:sku] == "CAN-001" }

      expect(camiseta).to include(
        qty_available: BigDecimal("-133.00"),
        qty_reserved: BigDecimal("0.000"),
        qty_safety_stock: nil,
        abc_curve: "C",
        lead_time_days: 0,
        infinite_inventory: false,
        last_modified_at: "2026-07-17T13:37:41.000Z"
      )
      expect(camiseta[:raw]).to include("QtyAvailable" => "-133.00")

      expect(caneca).to include(
        qty_available: BigDecimal("42.000"),
        qty_reserved: BigDecimal("5.000"),
        qty_safety_stock: BigDecimal("10.000"),
        abc_curve: "A",
        lead_time_days: 7,
        infinite_inventory: false
      )
    end

    it "extracts sku from IDSkuCompany (the confirmed real field) with a real-shaped numeric code" do
      raw = { "IDSku" => 999, "IDSkuCompany" => "0101", "CostLastPurchase" => 10.0, "CostAverage" => 9.0 }

      expect(adapter.send(:normalize_product, raw)[:sku]).to eq("0101")
    end

    it "still falls back to Sku when IDSkuCompany is absent (unconfirmed fallback, kept on purpose)" do
      raw = { "IDSku" => 999, "Sku" => "FALLBACK-1", "CostLastPurchase" => 10.0, "CostAverage" => 9.0 }

      expect(adapter.send(:normalize_product, raw)[:sku]).to eq("FALLBACK-1")
    end

    it "stops paginating once a page comes back empty" do
      stub_request(:get, sku_url).with(query: hash_including("Page" => "1"))
        .to_return(status: 200, body: { "Data" => [] }.to_json, headers: { "Content-Type" => "application/json" })

      adapter.fetch_products
      expect(WebMock).to have_requested(:get, sku_url).with(query: hash_including("Page" => "1"))
      expect(WebMock).not_to have_requested(:get, sku_url).with(query: hash_including("Page" => "2"))
    end
  end

  describe "#fetch_orders" do
    before do
      stub_signin
      # Same 0-indexed Page param as #fetch_products.
      stub_request(:get, orders_url)
        .with(query: hash_including("Page" => "0", "DateFrom" => "2026-06-01T00:00:00Z", "DateTo" => "2026-06-01T02:00:00Z"))
        .to_return(status: 200, body: orders_fixture, headers: { "Content-Type" => "application/json" })
      stub_request(:get, orders_url).with(query: hash_including("Page" => "1"))
        .to_return(status: 200, body: { "Data" => [] }.to_json, headers: { "Content-Type" => "application/json" })
    end

    it "requests the first page as Page=0, not Page=1" do
      adapter.fetch_orders(from: Time.utc(2026, 6, 1, 0, 0, 0), to: Time.utc(2026, 6, 1, 2, 0, 0))
      expect(WebMock).to have_requested(:get, orders_url).with(query: hash_including("Page" => "0"))
    end

    it "returns order_ref/idworks_order_id/value_shipping and related value fields" do
      orders = adapter.fetch_orders(from: Time.utc(2026, 6, 1, 0, 0, 0), to: Time.utc(2026, 6, 1, 2, 0, 0))

      raw_keys = %w[IDOrder Order ValueProduct ValueOrder ValueShipping ValuePaid]
      expect(orders).to contain_exactly(
        { order_ref: "555001", idworks_order_id: "88001", value_shipping: BigDecimal("15.30"), value_product: BigDecimal("180.00"), value_order: BigDecimal("199.90"), value_paid: BigDecimal("199.90"), sales_channel_slug: nil, raw_keys: raw_keys },
        { order_ref: "555999-NOT-IN-PRICECOM", idworks_order_id: "88002", value_shipping: BigDecimal("0"), value_product: BigDecimal("29.90"), value_order: BigDecimal("29.90"), value_paid: BigDecimal("29.90"), sales_channel_slug: nil, raw_keys: raw_keys }
      )
    end

    # SalesChannelLogoUrl confirmed 2026-08-17: not an enum, a logo URL —
    # the channel is the filename without extension, lowercased. See
    # Idworks::DashboardStatsService for the slug -> display name mapping.
    describe "sales_channel_slug (SalesChannelLogoUrl)" do
      def orders_with_logo_url(url)
        stub_request(:get, orders_url)
          .with(query: hash_including("Page" => "0", "DateFrom" => "2026-06-01T00:00:00Z", "DateTo" => "2026-06-01T02:00:00Z"))
          .to_return(status: 200, body: [ { "IDOrder" => 1, "Order" => "N1", "SalesChannelLogoUrl" => url } ].to_json, headers: { "Content-Type" => "application/json" })

        adapter.fetch_orders(from: Time.utc(2026, 6, 1, 0, 0, 0), to: Time.utc(2026, 6, 1, 2, 0, 0)).first[:sales_channel_slug]
      end

      it "extracts the lowercased filename without extension" do
        expect(orders_with_logo_url("https://cdn.idworks.com.br/logo/mercadolivre.png")).to eq("mercadolivre")
      end

      it "is resilient to a query string after the extension" do
        expect(orders_with_logo_url("https://cdn.idworks.com.br/logo/Shopify.png?v=2&x=1")).to eq("shopify")
      end

      it "is nil for a blank logo URL" do
        expect(orders_with_logo_url("")).to be_nil
        expect(orders_with_logo_url(nil)).to be_nil
      end
    end
  end

  # Field names confirmed against real hidrabene.api-idworks.com.br data on
  # 2026-07-27 — see IdworksAdapter#fetch_order_items's class comment for
  # the full discovery notes (SkuView=1, DateFrom/DateTo as plain
  # YYYY-MM-DD, Items already kit-decomposed by idworks itself).
  describe "#fetch_order_items" do
    let(:order_items_fixture) { File.read(Rails.root.join("spec/fixtures/integrations/idworks_orders_skuview_page0.json")) }

    before do
      stub_signin
      stub_request(:get, orders_url)
        .with(query: hash_including("Page" => "0", "SkuView" => "1", "DateFrom" => "2026-07-20", "DateTo" => "2026-07-27"))
        .to_return(status: 200, body: order_items_fixture, headers: { "Content-Type" => "application/json" })
      stub_request(:get, orders_url).with(query: hash_including("Page" => "1"))
        .to_return(status: 200, body: [].to_json, headers: { "Content-Type" => "application/json" })
    end

    it "requests SkuView=1 with plain-date DateFrom/DateTo" do
      adapter.fetch_order_items(from: Date.new(2026, 7, 20), to: Date.new(2026, 7, 27))

      expect(WebMock).to have_requested(:get, orders_url)
        .with(query: hash_including("Page" => "0", "SkuView" => "1", "DateFrom" => "2026-07-20", "DateTo" => "2026-07-27"))
    end

    it "flattens Items into idworks_order_id/sku/quantity rows, one per SKU line" do
      items = adapter.fetch_order_items(from: Date.new(2026, 7, 20), to: Date.new(2026, 7, 27))

      expect(items).to include(
        { idworks_order_id: "1001", sku: "SKU-A", quantity: BigDecimal("3") },
        { idworks_order_id: "1003", sku: "SKU-A", quantity: BigDecimal("2") }
      )
    end

    it "uses idworks' own kit decomposition (IDSkuCompany/Quantity) instead of the literal kit/pack SKU sold" do
      items = adapter.fetch_order_items(from: Date.new(2026, 7, 20), to: Date.new(2026, 7, 27))

      kit_order_items = items.select { |i| i[:idworks_order_id] == "1002" }
      expect(kit_order_items).to contain_exactly(
        { idworks_order_id: "1002", sku: "0107", quantity: BigDecimal("1") },
        { idworks_order_id: "1002", sku: "2080", quantity: BigDecimal("1") },
        { idworks_order_id: "1002", sku: "0109", quantity: BigDecimal("1") }
      )
      # "KIT044" (KitIDSkuCompany) never appears as a sku on its own — only
      # the real base-SKU components idworks already resolved it to.
      expect(items.map { |i| i[:sku] }).not_to include("KIT044")
    end

    it "already reflects the pack multiplier in Quantity for a pack SKU (2080_3 -> 3x base SKU 2080)" do
      items = adapter.fetch_order_items(from: Date.new(2026, 7, 20), to: Date.new(2026, 7, 27))

      pack_order_items = items.select { |i| i[:idworks_order_id] == "1004" }
      expect(pack_order_items).to contain_exactly({ idworks_order_id: "1004", sku: "2080", quantity: BigDecimal("3") })
    end
  end

  describe "#fetch_invoiced_order_ids" do
    let(:invoice_fixture) { File.read(Rails.root.join("spec/fixtures/integrations/idworks_invoice_list.json")) }
    let(:invoice_url) { "https://cliente.idworks.com.br/1.0/invoice" }

    before do
      stub_signin
      stub_request(:get, invoice_url)
        .with(query: hash_including("Page" => "0", "IDOrder" => "1001,1002,1003,1004"))
        .to_return(status: 200, body: invoice_fixture, headers: { "Content-Type" => "application/json" })
      stub_request(:get, invoice_url).with(query: hash_including("Page" => "1"))
        .to_return(status: 200, body: [].to_json, headers: { "Content-Type" => "application/json" })
    end

    it "returns only the order ids whose invoice has IDStatusInvoice == 3 (Emitida)" do
      ids = adapter.fetch_invoiced_order_ids(%w[1001 1002 1003 1004])

      expect(ids).to eq(Set.new(%w[1001 1002 1004])) # 1003's invoice is IDStatusInvoice=7 (Cancelada)
    end

    it "batches order_ids into the IDOrder comma-separated filter instead of one request per order" do
      adapter.fetch_invoiced_order_ids(%w[1001 1002 1003 1004])

      expect(WebMock).to have_requested(:get, invoice_url).with(query: hash_including("Page" => "0", "IDOrder" => "1001,1002,1003,1004")).once
    end

    it "returns an empty Set without any HTTP call when order_ids is empty" do
      expect(adapter.fetch_invoiced_order_ids([])).to eq(Set.new)
      expect(WebMock).not_to have_requested(:get, invoice_url)
    end
  end
end
