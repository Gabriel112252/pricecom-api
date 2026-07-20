require "rails_helper"

RSpec.describe StockAlerts::EvaluationService do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:product) { tenant.products.create!(sku: "SKU-1", name: "Produto 1", cost_price: 10, qty_available: 100) }

  def make_listing(channel: "shopify", stock_qty: 3, external_id: "ext-1")
    tenant.channel_product_listings.create!(product: product, channel: channel, external_id: external_id, stock_qty: stock_qty)
  end

  def make_rule(**overrides)
    tenant.stock_alert_rules.create!(
      { product: product, channel: "shopify", min_threshold: 5, target_level: 20 }.merge(overrides)
    )
  end

  describe "#call" do
    it "does nothing when there is no active rule for this product/channel" do
      listing = make_listing

      expect { described_class.call(listing) }.not_to change(StockAlert, :count)
    end

    it "does nothing when there is a rule but it's inactive" do
      make_rule(active: false)
      listing = make_listing

      expect { described_class.call(listing) }.not_to change(StockAlert, :count)
    end

    it "does nothing when stock_qty is above min_threshold" do
      make_rule(min_threshold: 5)
      listing = make_listing(stock_qty: 10)

      expect { described_class.call(listing) }.not_to change(StockAlert, :count)
    end

    it "creates a pending alert for a manual rule, with the correct suggested_replenishment_qty" do
      make_rule(automation_level: "manual", min_threshold: 5, target_level: 20)
      listing = make_listing(stock_qty: 3) # needed = 20-3 = 17; free_reserve = 100-3 = 97

      described_class.call(listing)

      alert = StockAlert.last
      expect(alert.status).to eq("pending")
      expect(alert.qty_at_trigger).to eq(BigDecimal("3"))
      expect(alert.target_level).to eq(BigDecimal("20"))
      expect(alert.suggested_replenishment_qty).to eq(BigDecimal("17"))
      expect(alert.automation_level_snapshot).to eq("manual")
      expect(alert.channel).to eq("shopify")
    end

    it "creates an awaiting_confirmation alert for a semi_automatic rule, without executing anything" do
      make_rule(automation_level: "semi_automatic")
      listing = make_listing(stock_qty: 3)

      expect(StockAlerts::ReplenishmentExecutorService).not_to receive(:call)
      described_class.call(listing)

      expect(StockAlert.last.status).to eq("awaiting_confirmation")
    end

    it "executes the replenishment right away for an automatic rule on a capable channel" do
      make_rule(automation_level: "automatic")
      listing = make_listing(channel: "shopify", stock_qty: 3)

      expect(StockAlerts::ReplenishmentExecutorService).to receive(:call).with(an_instance_of(StockAlert))
      described_class.call(listing)
    end

    it "falls back to a plain pending alert on TikTok even when the rule says automatic — TikTok has no working #update_stock yet" do
      make_rule(automation_level: "automatic", channel: "tiktok")
      listing = make_listing(channel: "tiktok", stock_qty: 3)

      expect(StockAlerts::ReplenishmentExecutorService).not_to receive(:call)
      described_class.call(listing)

      expect(StockAlert.last.status).to eq("pending")
    end

    it "creates an insufficient_reserve alert when the product has no free reserve to draw from" do
      make_rule(min_threshold: 5, target_level: 20)
      product.update!(qty_available: 3)
      listing = make_listing(stock_qty: 3) # free_reserve = 3 - 3 = 0

      expect(StockAlerts::ReplenishmentExecutorService).not_to receive(:call)
      described_class.call(listing)

      alert = StockAlert.last
      expect(alert.status).to eq("insufficient_reserve")
      expect(alert.suggested_replenishment_qty).to eq(BigDecimal("0"))
    end

    it "caps suggested_replenishment_qty at the free reserve when it's less than what's needed" do
      make_rule(min_threshold: 5, target_level: 20)
      product.update!(qty_available: 8) # free_reserve = 8 - 3 = 5, needed = 17
      listing = make_listing(stock_qty: 3)

      described_class.call(listing)

      expect(StockAlert.last.suggested_replenishment_qty).to eq(BigDecimal("5"))
    end

    it "refreshes the existing open alert instead of creating a duplicate on a second low-stock poll" do
      make_rule(automation_level: "manual")
      listing = make_listing(stock_qty: 3)
      described_class.call(listing)
      first_alert = StockAlert.last

      listing.update!(stock_qty: 1) # a later poll finds it even lower

      expect { described_class.call(listing) }.not_to change(StockAlert, :count)
      expect(first_alert.reload.qty_at_trigger).to eq(BigDecimal("1"))
    end

    it "does not touch a resolved (executed) alert from a previous cycle — a fresh low-stock event creates a new one" do
      make_rule(automation_level: "manual")
      listing = make_listing(stock_qty: 3)
      described_class.call(listing)
      StockAlert.last.update!(status: "executed", executed_at: Time.current)

      expect { described_class.call(listing) }.to change(StockAlert, :count).by(1)
    end
  end

  describe ".reevaluate_insufficient_reserves" do
    it "re-checks every channel with an open insufficient_reserve alert for that product" do
      make_rule(channel: "shopify", min_threshold: 5, target_level: 20)
      product.update!(qty_available: 3)
      listing = make_listing(channel: "shopify", stock_qty: 3) # free_reserve = 0 -> insufficient_reserve
      described_class.call(listing)
      expect(StockAlert.last.status).to eq("insufficient_reserve")

      product.update!(qty_available: 50) # now there's plenty of free reserve

      described_class.reevaluate_insufficient_reserves(product)

      expect(StockAlert.last.reload.status).to eq("pending")
      expect(StockAlert.count).to eq(1) # refreshed in place, not duplicated
    end

    it "does nothing when the product has no insufficient_reserve alerts" do
      expect(ChannelProductListing).not_to receive(:find_by)
      described_class.reevaluate_insufficient_reserves(product)
    end
  end
end
