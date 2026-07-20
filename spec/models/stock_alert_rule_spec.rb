require "rails_helper"

RSpec.describe StockAlertRule do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:product) { tenant.products.create!(sku: "SKU-1", name: "Produto 1", cost_price: 10) }

  def make_rule(**overrides)
    tenant.stock_alert_rules.create!(
      { product: product, channel: "shopify", min_threshold: 5, target_level: 20 }.merge(overrides)
    )
  end

  describe "validations" do
    it "is valid with the default attributes" do
      expect(make_rule).to be_valid
    end

    it "rejects an unknown channel" do
      rule = tenant.stock_alert_rules.new(product: product, channel: "amazon", min_threshold: 5, target_level: 20)

      expect(rule).not_to be_valid
      expect(rule.errors[:channel]).to be_present
    end

    it "rejects an unknown automation_level" do
      rule = tenant.stock_alert_rules.new(product: product, channel: "shopify", min_threshold: 5, target_level: 20, automation_level: "bogus")

      expect(rule).not_to be_valid
      expect(rule.errors[:automation_level]).to be_present
    end

    it "defaults automation_level to manual" do
      expect(make_rule.automation_level).to eq("manual")
    end

    it "requires target_level to be greater than min_threshold" do
      rule = tenant.stock_alert_rules.new(product: product, channel: "shopify", min_threshold: 10, target_level: 10)

      expect(rule).not_to be_valid
      expect(rule.errors[:target_level]).to be_present
    end

    it "requires target_level to be positive" do
      rule = tenant.stock_alert_rules.new(product: product, channel: "shopify", min_threshold: -5, target_level: 0)

      expect(rule).not_to be_valid
      expect(rule.errors[:target_level]).to be_present
    end

    it "rejects a negative min_threshold" do
      rule = tenant.stock_alert_rules.new(product: product, channel: "shopify", min_threshold: -1, target_level: 20)

      expect(rule).not_to be_valid
      expect(rule.errors[:min_threshold]).to be_present
    end

    it "enforces uniqueness of product+channel within a tenant" do
      make_rule

      dup = tenant.stock_alert_rules.new(product: product, channel: "shopify", min_threshold: 1, target_level: 2)

      expect(dup).not_to be_valid
      expect(dup.errors[:product_id]).to be_present
    end

    it "allows the same product on a different channel" do
      make_rule(channel: "shopify")

      other_channel = tenant.stock_alert_rules.new(product: product, channel: "yampi", min_threshold: 5, target_level: 20)

      expect(other_channel).to be_valid
    end
  end
end
