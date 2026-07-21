require "rails_helper"

# Regression coverage for a real production bug (tenant Hidrabene, TikTok
# order external_id 584933315891857248): Order#calculate_margin subtracts
# `discount` from gross_value, but TiktokOrderNormalizer#extract_discount
# used to fold payment.platform_discount (funded by TikTok, not the seller)
# into that same field, understating margin by the platform_discount
# amount. `discount` must now hold only the seller-funded discount.
RSpec.describe Order, type: :model do
  describe "#calculate_margin" do
    it "matches the TikTok settlement statement once discount excludes platform_discount" do
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

      # 118.90 - 9.84 - 0 - 42.04 = 67.02 (vs. the pre-fix 60.24, which
      # wrongly subtracted platform_discount too)
      expect(order.margin).to be_within(0.01).of(67.02)
      expect(order.margin_pct).to be_within(0.01).of(56.37)
    end
  end
end
