require "rails_helper"

# Regression coverage for TikTok margin rules. Unsynced orders preserve the
# legacy gross-value formula; finance-synced orders use settlement_amount and
# revenue_amount so platform-funded discounts are not subtracted again.
RSpec.describe Order, type: :model do
  describe "#calculate_margin" do
    it "keeps the legacy formula for an unsynchronized TikTok order" do
      tenant  = Tenant.create!(name: "Hidrabene", slug: "hidrabene-#{SecureRandom.hex(4)}")
      channel = tenant.channels.create!(platform: "tiktok", name: "TikTok Shop")

      order = tenant.orders.create!(
        channel:           channel,
        external_id:       "584933315891857248",
        order_type:        "sale",
        gross_value:       118.90,
        cost_price:        9.84,
        freight:           0.0,
        discount:          42.04, # seller_discount only, post-fix
        seller_discount:   42.04,
        platform_discount: 6.78   # audit-only, must NOT affect margin
      )

      # financial_synced_at is nil, so this remains the legacy calculation.
      expect(order.margin).to be_within(0.01).of(67.02)
      expect(order.margin_pct).to be_within(0.01).of(56.37)
    end

    it "uses settlement_amount and revenue_amount for a synchronized TikTok order" do
      tenant  = Tenant.create!(name: "Hidrabene", slug: "hidrabene-#{SecureRandom.hex(4)}")
      channel = tenant.channels.create!(platform: "tiktok", name: "TikTok Shop")

      order = tenant.orders.create!(
        channel: channel,
        external_id: "584549196646417968",
        order_type: "sale",
        gross_value: 36.46,
        cost_price: 5.58,
        freight: 0,
        discount: 18.52,
        seller_discount: 6.56,
        platform_discount: 11.96,
        revenue_amount: 29.90,
        settlement_amount: 17.83,
        fee_and_tax_amount: 12.07,
        commission: 12.07,
        financial_synced_at: Time.current
      )

      expect(order.margin).to eq(BigDecimal("12.25"))
      expect(order.margin_pct).to eq(BigDecimal("40.97"))
      expect(order.commission).to eq(BigDecimal("12.07"))
    end

    it "does not change a synchronized TikTok margin on a second calculation" do
      tenant  = Tenant.create!(name: "Hidrabene", slug: "hidrabene-#{SecureRandom.hex(4)}")
      channel = tenant.channels.create!(platform: "tiktok", name: "TikTok Shop")
      order = tenant.orders.create!(
        channel: channel,
        external_id: "584549196646417968-repeat",
        order_type: "sale",
        gross_value: 36.46,
        cost_price: 5.58,
        discount: 18.52,
        seller_discount: 6.56,
        platform_discount: 11.96,
        revenue_amount: 29.90,
        settlement_amount: 17.83,
        fee_and_tax_amount: 12.07,
        financial_synced_at: Time.current
      )
      original_values = [ order.margin, order.margin_pct ]

      order.calculate_margin
      order.save!

      expect([ order.reload.margin, order.margin_pct ]).to eq(original_values)
    end
  end
end
