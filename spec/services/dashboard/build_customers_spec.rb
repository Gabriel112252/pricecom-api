require "rails_helper"

RSpec.describe Dashboard::BuildCustomers do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:yampi) { tenant.channels.create!(name: "Yampi", platform: "yampi") }
  let(:tiktok) { tenant.channels.create!(name: "TikTok Shop", platform: "tiktok") }

  def make_order(channel, email:, ordered_at:, gross:, status: "paid")
    tenant.orders.create!(
      channel: channel, external_id: "order-#{SecureRandom.hex(4)}", order_number: "N1",
      order_type: "sale", status: status, customer_email: email,
      gross_value: gross, discount: 0, refund_amount: 0, ordered_at: ordered_at,
      cost_price: 0, commission: 0, operational_cost: 0
    )
  end

  def make_order_with_items(channel, email:, ordered_at:, gross:, items:, status: "paid")
    order = make_order(channel, email: email, ordered_at: ordered_at, gross: gross, status: status)
    items.each do |item|
      sku = item.fetch(:sku)
      name = item.fetch(:name, sku)
      quantity = item.fetch(:quantity, 1)
      is_gift = item.fetch(:is_gift, false)
      product = item.key?(:product) ? item[:product] : tenant.products.find_or_create_by!(sku: sku) { |p| p.name = name }
      order.order_items.create!(product: product, sku: sku, name: name, quantity: quantity, unit_price: 10, is_gift: is_gift)
    end
    order
  end

  describe "unsupported channels" do
    it "returns supported: false for tiktok, with no calculations attempted" do
      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(channel: "tiktok"))

      expect(result[:supported]).to eq(false)
      expect(result[:unsupported_reason]).to be_present
      expect(result[:repeat_purchase_rate]).to be_nil
      expect(result[:repeat_order_share]).to be_nil
      expect(result[:repurchase_gap_histogram]).to be_nil
      expect(result[:repeat_product_rankings]).to eq(
        by_volume: [], by_customer_pct: [], min_customers_threshold: 20
      )
    end

    it "defaults to yampi when no channel param is given" do
      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new)
      expect(result[:channel]).to eq("yampi")
      expect(result[:supported]).to eq(true)
    end
  end

  describe "repeat_purchase_rate" do
    it "counts only customers with 2+ valid orders inside the period as repeat customers" do
      make_order(yampi, email: "a@ex.com", ordered_at: 5.days.ago, gross: 100)
      make_order(yampi, email: "a@ex.com", ordered_at: 2.days.ago, gross: 100)
      make_order(yampi, email: "b@ex.com", ordered_at: 1.day.ago, gross: 50)
      make_order(yampi, email: nil, ordered_at: 1.day.ago, gross: 30)
      make_order(yampi, email: "c@ex.com", ordered_at: 1.day.ago, gross: 10, status: "cancelado")

      result = described_class.call(
        tenant: tenant,
        params: ActionController::Parameters.new(channel: "yampi", from: 10.days.ago.to_date.iso8601, to: Date.current.iso8601)
      )

      rate = result[:repeat_purchase_rate]
      expect(rate[:total_customers]).to eq(2) # a and b (nil-email order and canceled order excluded)
      expect(rate[:repeat_customers]).to eq(1) # only a
      expect(rate[:value_pct]).to eq(50.0)
      expect(rate[:orders_without_customer_email_count]).to eq(1)
    end

    it "only counts orders on the OTHER channel toward that channel's own rate" do
      make_order(yampi, email: "a@ex.com", ordered_at: 1.day.ago, gross: 100)
      make_order(tiktok, email: "a@ex.com", ordered_at: 1.day.ago, gross: 100)

      result = described_class.call(
        tenant: tenant,
        params: ActionController::Parameters.new(channel: "yampi", from: 10.days.ago.to_date.iso8601, to: Date.current.iso8601)
      )

      expect(result[:repeat_purchase_rate][:total_customers]).to eq(1)
    end

    it "builds a per-bucket timeline with the same 2+/1+ formula, zero-filling empty buckets" do
      make_order(yampi, email: "a@ex.com", ordered_at: 3.days.ago, gross: 100)
      make_order(yampi, email: "a@ex.com", ordered_at: 3.days.ago, gross: 100)
      make_order(yampi, email: "b@ex.com", ordered_at: 1.day.ago, gross: 50)

      result = described_class.call(
        tenant: tenant,
        params: ActionController::Parameters.new(channel: "yampi", from: 3.days.ago.to_date.iso8601, to: Date.current.iso8601)
      )

      timeline = result[:repeat_purchase_rate][:timeline].index_by { |b| b[:bucket] }
      three_days_ago_bucket = timeline[3.days.ago.to_date.iso8601]
      one_day_ago_bucket = timeline[1.day.ago.to_date.iso8601]
      today_bucket = timeline[Date.current.iso8601]

      expect(three_days_ago_bucket[:value_pct]).to eq(100.0)
      expect(three_days_ago_bucket[:total_customers]).to eq(1)
      expect(three_days_ago_bucket[:repeat_customers]).to eq(1)

      expect(one_day_ago_bucket[:value_pct]).to eq(0.0)
      expect(one_day_ago_bucket[:total_customers]).to eq(1)

      expect(today_bucket[:value_pct]).to be_nil
      expect(today_bucket[:total_customers]).to eq(0)
    end
  end

  describe "repeat_order_share" do
    it "never counts a customer's very first order ever as repeat, even if it falls inside the period" do
      make_order(yampi, email: "a@ex.com", ordered_at: 1.day.ago, gross: 100)

      result = described_class.call(
        tenant: tenant,
        params: ActionController::Parameters.new(channel: "yampi", from: 10.days.ago.to_date.iso8601, to: Date.current.iso8601)
      )

      expect(result[:repeat_order_share][:total_orders]).to eq(1)
      expect(result[:repeat_order_share][:repeat_orders]).to eq(0)
      expect(result[:repeat_order_share][:value_pct]).to eq(0.0)
    end

    it "counts a customer's 2nd+ order inside the period as repeat" do
      make_order(yampi, email: "a@ex.com", ordered_at: 5.days.ago, gross: 100)
      make_order(yampi, email: "a@ex.com", ordered_at: 2.days.ago, gross: 100)

      result = described_class.call(
        tenant: tenant,
        params: ActionController::Parameters.new(channel: "yampi", from: 10.days.ago.to_date.iso8601, to: Date.current.iso8601)
      )

      expect(result[:repeat_order_share][:total_orders]).to eq(2)
      expect(result[:repeat_order_share][:repeat_orders]).to eq(1)
      expect(result[:repeat_order_share][:value_pct]).to eq(50.0)
    end

    it "counts an in-period order as repeat when the customer's first order is outside the period (full history)" do
      make_order(yampi, email: "a@ex.com", ordered_at: 40.days.ago, gross: 100) # outside the period
      make_order(yampi, email: "a@ex.com", ordered_at: Time.current, gross: 100) # inside the period

      result = described_class.call(
        tenant: tenant,
        params: ActionController::Parameters.new(channel: "yampi", from: 10.days.ago.to_date.iso8601, to: Date.current.iso8601)
      )

      expect(result[:repeat_order_share][:total_orders]).to eq(1) # only the in-period order counted in the denominator
      expect(result[:repeat_order_share][:repeat_orders]).to eq(1)
      expect(result[:repeat_order_share][:value_pct]).to eq(100.0)
    end

    it "excludes orders without a customer_email from numerator and denominator" do
      make_order(yampi, email: "a@ex.com", ordered_at: 1.day.ago, gross: 100)
      make_order(yampi, email: nil, ordered_at: 1.day.ago, gross: 30)

      result = described_class.call(
        tenant: tenant,
        params: ActionController::Parameters.new(channel: "yampi", from: 10.days.ago.to_date.iso8601, to: Date.current.iso8601)
      )

      expect(result[:repeat_order_share][:total_orders]).to eq(1)
      expect(result[:repeat_order_share][:orders_without_customer_email_count]).to eq(1)
    end
  end

  describe "repurchase_gap_histogram" do
    it "contributes zero gap points for a customer with only 1 valid order" do
      make_order(yampi, email: "a@ex.com", ordered_at: 1.day.ago, gross: 100)

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(channel: "yampi"))

      expect(result[:repurchase_gap_histogram][:sample_size]).to eq(0)
      expect(result[:repurchase_gap_histogram][:median_days]).to be_nil
    end

    it "buckets consecutive gaps for a customer with several orders, each gap an independent data point" do
      make_order(yampi, email: "a@ex.com", ordered_at: 50.days.ago, gross: 100)
      make_order(yampi, email: "a@ex.com", ordered_at: 40.days.ago, gross: 100) # gap 1: 10 days -> 0-15
      make_order(yampi, email: "a@ex.com", ordered_at: 0.days.ago,  gross: 100) # gap 2: 40 days -> 30-60

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(channel: "yampi"))
      buckets = result[:repurchase_gap_histogram][:buckets].index_by { |b| b[:range] }

      expect(result[:repurchase_gap_histogram][:sample_size]).to eq(2)
      expect(buckets["0-15"][:customers_count]).to eq(1)
      expect(buckets["30-60"][:customers_count]).to eq(1)
      expect(buckets["15-30"][:customers_count]).to eq(0)
    end

    it "places a gap of exactly a boundary value in the higher half-open bucket" do
      make_order(yampi, email: "a@ex.com", ordered_at: 15.days.ago, gross: 100)
      make_order(yampi, email: "a@ex.com", ordered_at: 0.days.ago, gross: 100) # gap: exactly 15.0 days

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(channel: "yampi"))
      buckets = result[:repurchase_gap_histogram][:buckets].index_by { |b| b[:range] }

      expect(buckets["15-30"][:customers_count]).to eq(1)
      expect(buckets["0-15"][:customers_count]).to eq(0)
    end

    it "computes the median (not mean) over all gaps, for odd and even sample sizes" do
      make_order(yampi, email: "a@ex.com", ordered_at: 30.days.ago, gross: 100)
      make_order(yampi, email: "a@ex.com", ordered_at: 20.days.ago, gross: 100) # gap: 10
      make_order(yampi, email: "a@ex.com", ordered_at: 0.days.ago, gross: 100)  # gap: 20

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(channel: "yampi"))
      expect(result[:repurchase_gap_histogram][:median_days]).to eq(15.0) # even sample: avg of 10 and 20

      make_order(yampi, email: "b@ex.com", ordered_at: 6.days.ago, gross: 100)
      make_order(yampi, email: "b@ex.com", ordered_at: 1.day.ago, gross: 100) # gap: 5

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(channel: "yampi"))
      expect(result[:repurchase_gap_histogram][:median_days]).to eq(10.0) # odd sample [5, 10, 20] -> middle
    end
  end

  describe "repeat_product_rankings" do
    it "counts a product's 2nd+ purchase by the same customer toward the volume ranking" do
      make_order_with_items(yampi, email: "a@ex.com", ordered_at: 10.days.ago, gross: 100, items: [{ sku: "SKU1" }])
      make_order_with_items(yampi, email: "a@ex.com", ordered_at: 5.days.ago, gross: 100, items: [{ sku: "SKU1" }])

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(channel: "yampi"))
      by_volume = result[:repeat_product_rankings][:by_volume].index_by { |p| p[:sku] }

      expect(by_volume["SKU1"][:repeat_purchase_count]).to eq(1)
    end

    it "excludes a product bought once each by many different customers from the volume ranking" do
      3.times do |i|
        make_order_with_items(yampi, email: "c#{i}@ex.com", ordered_at: 1.day.ago, gross: 100, items: [{ sku: "SKU2" }])
      end

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(channel: "yampi"))
      expect(result[:repeat_product_rankings][:by_volume].map { |p| p[:sku] }).not_to include("SKU2")
    end

    it "applies the minimum-customers floor to the % ranking, excluding low-N products even at 100% repeat" do
      threshold = Dashboard::BuildCustomers::MIN_CUSTOMERS_FOR_PRODUCT_PCT_RANKING

      (threshold - 1).times do |i|
        email = "below#{i}@ex.com"
        make_order_with_items(yampi, email: email, ordered_at: 10.days.ago, gross: 100, items: [{ sku: "BELOW-FLOOR" }])
        make_order_with_items(yampi, email: email, ordered_at: 5.days.ago, gross: 100, items: [{ sku: "BELOW-FLOOR" }])
      end

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(channel: "yampi"))
      expect(result[:repeat_product_rankings][:by_customer_pct].map { |p| p[:sku] }).not_to include("BELOW-FLOOR")

      email = "extra@ex.com"
      make_order_with_items(yampi, email: email, ordered_at: 10.days.ago, gross: 100, items: [{ sku: "BELOW-FLOOR" }])
      make_order_with_items(yampi, email: email, ordered_at: 5.days.ago, gross: 100, items: [{ sku: "BELOW-FLOOR" }])

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(channel: "yampi"))
      at_floor = result[:repeat_product_rankings][:by_customer_pct].find { |p| p[:sku] == "BELOW-FLOOR" }

      expect(at_floor).to be_present
      expect(at_floor[:customers_count]).to eq(threshold)
      expect(at_floor[:repeat_customers_pct]).to eq(100.0)
    end

    it "excludes gift items and items without a linked product, while still counting a valid item on the same order" do
      real_product = tenant.products.create!(sku: "REAL", name: "Produto real")
      valid_product = tenant.products.create!(sku: "VALID", name: "Produto válido")

      2.times do |i|
        order = make_order(yampi, email: "a@ex.com", ordered_at: (10 - i).days.ago, gross: 100)
        order.order_items.create!(product: real_product, sku: "REAL", name: "Produto real", quantity: 1, unit_price: 10, is_gift: true)
        order.order_items.create!(product: nil, sku: "NOPROD", name: "Sem produto", quantity: 1, unit_price: 10, is_gift: false)
        order.order_items.create!(product: valid_product, sku: "VALID", name: "Produto válido", quantity: 1, unit_price: 10, is_gift: false)
      end

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(channel: "yampi"))

      skus = result[:repeat_product_rankings][:by_volume].map { |p| p[:sku] } +
        result[:repeat_product_rankings][:by_customer_pct].map { |p| p[:sku] }
      expect(skus).not_to include("REAL", "NOPROD")
      expect(result[:repeat_product_rankings][:by_volume].find { |p| p[:sku] == "VALID" }[:repeat_purchase_count]).to eq(1)
    end

    it "only counts orders on the OTHER channel toward that channel's own product rankings" do
      product = tenant.products.create!(sku: "CROSSCHAN", name: "Produto cross-channel")
      2.times do
        order = make_order(tiktok, email: "a@ex.com", ordered_at: 1.day.ago, gross: 100)
        order.order_items.create!(product: product, sku: "CROSSCHAN", name: "Produto cross-channel", quantity: 1, unit_price: 10, is_gift: false)
      end

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(channel: "yampi"))
      expect(result[:repeat_product_rankings][:by_volume].map { |p| p[:sku] }).not_to include("CROSSCHAN")
    end
  end
end
