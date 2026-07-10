require "rails_helper"

RSpec.describe Integrations::OrderStockDeductionService do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }

  def make_channel(platform)
    tenant.channels.create!(name: platform.capitalize, platform: platform)
  end

  def make_credential(channel_name, role:, stock_source_channel: nil)
    tenant.channel_credentials.create!(
      channel: channel_name,
      status: "active",
      role: role,
      stock_source_channel: stock_source_channel,
      credentials: { alias: "a", token: "t", secret_key: "s", shop_domain: "x", access_token: "y", app_key: "k", app_secret: "s2", webhook_secret: "wh" }
    )
  end

  def make_listing(channel_name, product, stock_qty: 10)
    ChannelProductListing.create!(
      tenant: tenant, product: product, channel: channel_name,
      external_id: "ext-#{product.id}-#{channel_name}", external_sku: product.sku,
      stock_qty: stock_qty, price: 10, synced_at: Time.current
    )
  end

  def make_order(channel, order_type: "sale")
    tenant.orders.create!(
      channel: channel, external_id: "order-#{SecureRandom.hex(4)}", order_number: "N1",
      order_type: order_type, gross_value: 100, ordered_at: Time.current
    )
  end

  let(:product) { tenant.products.create!(sku: "SKU-1", name: "Produto 1", cost_price: 5) }

  describe "channel with role=fonte_estoque (Shopify)" do
    it "debits the channel's own ChannelProductListing" do
      shopify_channel = make_channel("shopify")
      make_credential("shopify", role: "fonte_estoque")
      listing = make_listing("shopify", product, stock_qty: 10)

      order = make_order(shopify_channel)
      order.order_items.create!(product: product, sku: product.sku, name: product.name, quantity: 3, unit_price: 10, unit_cost: 5)

      result = described_class.call(order)

      expect(result.outcome).to eq(:success)
      expect(listing.reload.stock_qty).to eq(BigDecimal("7"))
      expect(order.reload.stock_deducted_at).to be_present
    end
  end

  describe "channel with role=consumidor_pedido pointing at another channel (Yampi -> Shopify)" do
    it "debits the SOURCE channel's listing, not its own — and never creates a Yampi listing" do
      shopify_credential = make_credential("shopify", role: "fonte_estoque")
      yampi_channel = make_channel("yampi")
      make_credential("yampi", role: "consumidor_pedido", stock_source_channel: shopify_credential)

      shopify_listing = make_listing("shopify", product, stock_qty: 10)

      order = make_order(yampi_channel)
      order.order_items.create!(product: product, sku: product.sku, name: product.name, quantity: 4, unit_price: 10, unit_cost: 5)

      result = described_class.call(order)

      expect(result.outcome).to eq(:success)
      expect(result.metadata[:source_channel]).to eq("shopify")
      expect(shopify_listing.reload.stock_qty).to eq(BigDecimal("6"))
      # The whole point: no phantom "yampi" listing was created for this product.
      expect(ChannelProductListing.where(tenant: tenant, channel: "yampi", product: product)).to be_empty
    end
  end

  describe "channel with role=ambos (TikTok)" do
    it "debits its own listing, same as fonte_estoque" do
      tiktok_channel = make_channel("tiktok")
      make_credential("tiktok", role: "ambos")
      listing = make_listing("tiktok", product, stock_qty: 20)

      order = make_order(tiktok_channel)
      order.order_items.create!(product: product, sku: product.sku, name: product.name, quantity: 2, unit_price: 10, unit_cost: 5)

      result = described_class.call(order)

      expect(result.outcome).to eq(:success)
      expect(listing.reload.stock_qty).to eq(BigDecimal("18"))
    end
  end

  describe "kit products" do
    it "debits the real components via Products::ExplodeKit, not the kit itself" do
      shopify_channel = make_channel("shopify")
      make_credential("shopify", role: "fonte_estoque")

      component_a = tenant.products.create!(sku: "COMP-A", name: "Componente A", cost_price: 2)
      component_b = tenant.products.create!(sku: "COMP-B", name: "Componente B", cost_price: 3)
      kit = tenant.products.create!(sku: "KIT-1", name: "Kit", cost_price: 0, is_kit: true)
      kit.kit_components.create!(component_product: component_a, quantity: 2)
      kit.kit_components.create!(component_product: component_b, quantity: 1)

      listing_a = make_listing("shopify", component_a, stock_qty: 10)
      listing_b = make_listing("shopify", component_b, stock_qty: 10)
      kit_listing = make_listing("shopify", kit, stock_qty: 999)

      order = make_order(shopify_channel)
      order.order_items.create!(product: kit, sku: kit.sku, name: kit.name, quantity: 3, unit_price: 30, unit_cost: 0)

      described_class.call(order)

      expect(listing_a.reload.stock_qty).to eq(BigDecimal("4"))  # 10 - (2 * 3)
      expect(listing_b.reload.stock_qty).to eq(BigDecimal("7"))  # 10 - (1 * 3)
      expect(kit_listing.reload.stock_qty).to eq(BigDecimal("999")) # untouched — the kit itself isn't a real SKU
    end
  end

  describe "idempotency" do
    it "only deducts once even if called twice for the same order" do
      shopify_channel = make_channel("shopify")
      make_credential("shopify", role: "fonte_estoque")
      listing = make_listing("shopify", product, stock_qty: 10)

      order = make_order(shopify_channel)
      order.order_items.create!(product: product, sku: product.sku, name: product.name, quantity: 3, unit_price: 10, unit_cost: 5)

      first = described_class.call(order)
      second = described_class.call(order.reload)

      expect(first.outcome).to eq(:success)
      expect(second.outcome).to eq(:skipped)
      expect(listing.reload.stock_qty).to eq(BigDecimal("7")) # not 4 — only deducted once
    end
  end

  describe "non-sale orders" do
    it "does not deduct stock for a refund/cancellation" do
      shopify_channel = make_channel("shopify")
      make_credential("shopify", role: "fonte_estoque")
      listing = make_listing("shopify", product, stock_qty: 10)

      order = make_order(shopify_channel, order_type: "refund")
      order.order_items.create!(product: product, sku: product.sku, name: product.name, quantity: 3, unit_price: 10, unit_cost: 5)

      result = described_class.call(order)

      expect(result.outcome).to eq(:skipped)
      expect(listing.reload.stock_qty).to eq(BigDecimal("10"))
    end
  end

  describe "a channel never connected to the sync system" do
    it "skips gracefully without raising" do
      mercadolivre_channel = make_channel("mercadolivre") # no ChannelCredential created for it

      order = make_order(mercadolivre_channel)
      order.order_items.create!(product: product, sku: product.sku, name: product.name, quantity: 1, unit_price: 10, unit_cost: 5)

      result = described_class.call(order)

      expect(result.outcome).to eq(:skipped)
      expect(order.reload.stock_deducted_at).to be_present
    end
  end
end
