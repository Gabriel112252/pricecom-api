require "rails_helper"

# Regression coverage for two real production bugs, both confirmed against
# the official TikTok Shop settlement statement for tenant Hidrabene, order
# external_id 584933315891857248:
#
# 1. gross_value used to be payment.total_amount, which per the Get Order
#    List 202309 doc is the POST-discount amount the buyer paid
#    (total_amount = sub_total + shipping_fee + taxes, with sub_total
#    already net of seller/platform discounts). Order#calculate_margin
#    subtracts `discount` from gross_value, so the discount was
#    double-counted and production showed impossible orders where
#    discount > gross_value. gross_value must be the PRE-discount total:
#    original_total_product_price + buyer-paid shipping_fee.
#
# 2. discount used to be payment.seller_discount + payment.platform_discount
#    combined. platform_discount is funded by TikTok, not the seller — the
#    settlement statement's "Vendas líquidas dos produtos" nets out only
#    seller_discount (118.90 - 42.04 = 76.86), so folding platform_discount
#    into `discount` overstated the amount subtracted from the seller's
#    margin by exactly the platform_discount (here, R$ 6.78: stored
#    discount was 48.82 instead of the correct 42.04).
RSpec.describe Integrations::Normalizers::TiktokOrderNormalizer do
  let(:orders_fixture) { JSON.parse(File.read(Rails.root.join("spec/fixtures/integrations/tiktok_orders.json"))) }
  let(:raw_order) { orders_fixture.dig("data", "orders").first }
  let(:normalized) { described_class.new(raw_order, "order.polling").normalize }

  describe "order totals (Get Order List 202309 payment{} semantics)" do
    it "sets gross_value to the PRE-discount total (original products + paid shipping), not total_amount" do
      # original_total_product_price 118.90 + shipping_fee 6.84
      expect(normalized[:gross_value]).to be_within(0.001).of(125.74)
      expect(normalized[:gross_value]).not_to be_within(0.001).of(76.92)
    end

    it "extracts only seller_discount into discount, excluding platform_discount" do
      expect(normalized[:discount]).to be_within(0.001).of(42.04)
    end

    it "extracts platform_discount separately, for audit only" do
      expect(normalized[:platform_discount]).to be_within(0.001).of(6.78)
    end

    it "uses the buyer-paid shipping_fee as freight" do
      expect(normalized[:freight]).to be_within(0.001).of(6.84)
    end

    it "keeps the shipping fee decomposition for freight-margin auditing" do
      expect(normalized[:original_shipping_fee]).to be_within(0.001).of(10.00)
      expect(normalized[:shipping_fee_seller_discount]).to be_within(0.001).of(3.16)
      expect(normalized[:shipping_fee_platform_discount]).to eq(0.0)
    end

    it "leaves shipping fee audit fields nil when the payload has no payment object" do
      bare = described_class.new({ "id" => "1", "status" => "UNPAID" }, "order.polling").normalize

      expect(bare[:original_shipping_fee]).to be_nil
      expect(bare[:shipping_fee_seller_discount]).to be_nil
      expect(bare[:shipping_fee_platform_discount]).to be_nil
      expect(bare[:platform_discount]).to eq(0.0)
    end
  end

  describe "status normalization" do
    it "maps UNPAID (any casing) to the canonical 'unpaid'" do
      %w[UNPAID unpaid Unpaid].each do |raw_status|
        result = described_class.new(raw_order.merge("status" => raw_status), "order.polling").normalize
        expect(result[:status]).to eq("unpaid")
        expect(result[:order_type]).to eq("sale")
      end
    end

    it "keeps every other status verbatim" do
      result = described_class.new(raw_order.merge("status" => "AWAITING_SHIPMENT"), "order.polling").normalize
      expect(result[:status]).to eq("AWAITING_SHIPMENT")
    end
  end

  describe "order fields" do
    it "extracts id, status, payment method and recipient" do
      expect(normalized).to include(
        external_id:    "580100000000000001",
        status:         "COMPLETED",
        payment_method: "PIX",
        customer_name:  "Cliente Exemplo",
        order_type:     "sale"
      )
    end

    it "extracts the state from district_info (L1/State), not a flat state key" do
      expect(normalized[:state]).to eq("SP")
    end

    it "parses create_time (unix seconds) into ordered_at" do
      expect(normalized[:ordered_at]).to eq(Time.zone.at(1_752_345_600))
    end
  end

  describe "line items (one line item per unit, no quantity field)" do
    it "groups identical-SKU line items into one item with summed quantity and discount" do
      expect(normalized[:items].size).to eq(1)
      expect(normalized[:items].first).to include(
        sku:                 "CAMISA-P",
        name:                "Camisa Básica P",
        quantity:            2,
        external_product_id: "999888777",
        is_gift:             false
      )
      expect(normalized[:items].first[:unit_price]).to be_within(0.001).of(35.04)
      # 2 × (seller_discount 21.02 + platform_discount 3.39) — per-item
      # discount is untouched by this fix (out of scope: it isn't read by
      # Order#calculate_margin, only the order-level `discount` is)
      expect(normalized[:items].first[:discount]).to be_within(0.001).of(48.82)
    end
  end

  describe "payloads without a payment{} hash (defensive webhook shape)" do
    it "rebuilds the pre-discount gross from line item original_price + shipping_fee" do
      payload = {
        "id" => "580100000000000002",
        "status" => "AWAITING_SHIPMENT",
        "shipping_fee" => "5.00",
        "line_items" => [
          { "sku_id" => "1", "seller_sku" => "SKU-A", "original_price" => "50.00", "sale_price" => "40.00" }
        ]
      }

      result = described_class.new(payload, "").normalize

      expect(result[:gross_value]).to be_within(0.001).of(55.00)
      expect(result[:freight]).to be_within(0.001).of(5.00)
    end

    it "falls back to paid total + discount when no pre-discount info exists at all" do
      payload = {
        "id" => "580100000000000003",
        "status" => "COMPLETED",
        "total_amount" => "90.00",
        "discount" => "10.00",
        "line_items" => []
      }

      result = described_class.new(payload, "").normalize

      # 90.00 paid + 10.00 discount = 100.00 pre-discount gross
      expect(result[:gross_value]).to be_within(0.001).of(100.00)
    end
  end
end
