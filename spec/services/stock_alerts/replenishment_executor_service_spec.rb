require "rails_helper"

RSpec.describe StockAlerts::ReplenishmentExecutorService do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:product) { tenant.products.create!(sku: "SKU-1", name: "Produto 1", cost_price: 10, qty_available: 100) }

  def make_alert(channel:, stock_qty:, suggested_replenishment_qty:, status: "awaiting_confirmation")
    tenant.stock_alerts.create!(
      product: product, channel: channel, qty_at_trigger: stock_qty, target_level: stock_qty + suggested_replenishment_qty,
      suggested_replenishment_qty: suggested_replenishment_qty, automation_level_snapshot: "semi_automatic", status: status
    )
  end

  describe "shopify" do
    let(:base_url) { "https://minha-loja.myshopify.com/admin/api/2024-01" }
    let!(:credential) do
      tenant.channel_credentials.create!(
        channel: "shopify", status: "active",
        credentials: { shop_domain: "minha-loja.myshopify.com", access_token: "shpat_abc123", webhook_secret: "wh" }
      )
    end
    let!(:listing) do
      tenant.channel_product_listings.create!(
        product: product, channel: "shopify", external_id: "808950810",
        external_inventory_item_id: "39072856", stock_qty: 3
      )
    end

    def stub_shopify_write(available: 8)
      stub_request(:get, "#{base_url}/locations.json")
        .to_return(status: 200, body: { locations: [ { id: 1, active: true, legacy: false } ] }.to_json,
                   headers: { "Content-Type" => "application/json" })
      stub_request(:post, "#{base_url}/inventory_levels/set.json")
        .to_return(status: 200, body: { inventory_level: { available: available } }.to_json,
                   headers: { "Content-Type" => "application/json" })
    end

    it "writes the new absolute quantity and marks the alert executed" do
      stub_shopify_write
      alert = make_alert(channel: "shopify", stock_qty: 3, suggested_replenishment_qty: 5)

      result = described_class.call(alert)

      expect(result.success?).to eq(true)
      expect(alert.reload.status).to eq("executed")
      expect(alert.executed_at).to be_present
      expect(listing.reload.stock_qty).to eq(BigDecimal("8"))
      expect(WebMock).to have_requested(:post, "#{base_url}/inventory_levels/set.json")
        .with(body: { location_id: 1, inventory_item_id: 39072856, available: 8 }.to_json)
    end

    it "marks the alert failed (without raising) when Shopify rejects the credentials" do
      stub_request(:get, "#{base_url}/locations.json").to_return(status: 401, body: { errors: "Invalid" }.to_json)
      alert = make_alert(channel: "shopify", stock_qty: 3, suggested_replenishment_qty: 5)

      result = described_class.call(alert)

      expect(result.error?).to eq(true)
      expect(alert.reload.status).to eq("failed")
      expect(alert.error_message).to be_present
    end

    it "fails clearly, without an HTTP call, when the listing has no external_inventory_item_id yet" do
      listing.update!(external_inventory_item_id: nil)
      alert = make_alert(channel: "shopify", stock_qty: 3, suggested_replenishment_qty: 5)

      result = described_class.call(alert)

      expect(result.error?).to eq(true)
      expect(alert.reload.status).to eq("failed")
      expect(alert.error_message).to match(/external_inventory_item_id/)
      expect(WebMock).not_to have_requested(:get, "#{base_url}/locations.json")
    end
  end

  describe "yampi" do
    let(:stocks_url) { "https://api.dooki.com.br/v2/minha-loja/catalog/skus/987001/stocks" }
    let!(:credential) do
      tenant.channel_credentials.create!(
        channel: "yampi", status: "active",
        credentials: { alias: "minha-loja", token: "tok123", secret_key: "sec456", webhook_secret: "wh" }
      )
    end
    let!(:listing) do
      tenant.channel_product_listings.create!(product: product, channel: "yampi", external_id: "987001", stock_qty: 3)
    end

    it "writes via PUT after resolving the single stock record, and marks the alert executed" do
      stub_request(:get, stocks_url).with(query: hash_including("page" => "1"))
        .to_return(status: 200, body: { data: [ { id: 1, stock_id: 5, quantity: 3, min_quantity: 10 } ],
                                         meta: { pagination: { total_pages: 1 } } }.to_json,
                   headers: { "Content-Type" => "application/json" })
      stub_request(:put, "#{stocks_url}/1")
        .to_return(status: 200, body: { data: { id: 1, stock_id: 5, quantity: 8, min_quantity: 10 } }.to_json,
                   headers: { "Content-Type" => "application/json" })

      alert = make_alert(channel: "yampi", stock_qty: 3, suggested_replenishment_qty: 5)
      result = described_class.call(alert)

      expect(result.success?).to eq(true)
      expect(alert.reload.status).to eq("executed")
      expect(listing.reload.stock_qty).to eq(BigDecimal("8"))
    end
  end

  describe "tiktok (automation-incapable channel)" do
    it "fails immediately without touching credentials/listings/network" do
      alert = make_alert(channel: "tiktok", stock_qty: 3, suggested_replenishment_qty: 5)

      expect(ChannelCredential).not_to receive(:find_by)
      result = described_class.call(alert)

      expect(result.error?).to eq(true)
      expect(alert.reload.status).to eq("failed")
      expect(alert.error_message).to eq("canal sem capacidade de escrita automática")
    end
  end

  describe "missing listing/credential" do
    it "fails clearly when there is no ChannelProductListing for this product/channel" do
      alert = make_alert(channel: "shopify", stock_qty: 3, suggested_replenishment_qty: 5)

      result = described_class.call(alert)

      expect(result.error?).to eq(true)
      expect(alert.reload.error_message).to match(/ChannelProductListing/)
    end

    it "fails clearly when the channel has no connected credential" do
      tenant.channel_product_listings.create!(product: product, channel: "shopify", external_id: "1", stock_qty: 3)
      alert = make_alert(channel: "shopify", stock_qty: 3, suggested_replenishment_qty: 5)

      result = described_class.call(alert)

      expect(result.error?).to eq(true)
      expect(alert.reload.error_message).to match(/credencial/)
    end
  end
end
