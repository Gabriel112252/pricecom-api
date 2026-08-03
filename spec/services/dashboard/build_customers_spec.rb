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

  describe "unsupported channels" do
    it "returns supported: false for tiktok, with no calculations attempted" do
      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(channel: "tiktok"))

      expect(result[:supported]).to eq(false)
      expect(result[:unsupported_reason]).to be_present
      expect(result[:repeat_purchase_rate]).to be_nil
      expect(result[:rfm_segments]).to eq([])
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
  end

  describe "revenue_by_customer_type" do
    it "classifies a customer's very first valid order ever as new, later ones as returning" do
      make_order(yampi, email: "a@ex.com", ordered_at: 40.days.ago, gross: 100)  # first order, OUTSIDE the period
      make_order(yampi, email: "a@ex.com", ordered_at: Time.current, gross: 200) # 2nd order, INSIDE the period -> returning
      make_order(yampi, email: "b@ex.com", ordered_at: Time.current, gross: 80)  # customer b's only/first order -> new

      result = described_class.call(
        tenant: tenant,
        params: ActionController::Parameters.new(channel: "yampi", from: 10.days.ago.to_date.iso8601, to: Date.current.iso8601)
      )

      today_bucket = result[:revenue_by_customer_type][:timeline].last
      expect(today_bucket[:new_customer_revenue]).to eq(80.0)
      expect(today_bucket[:returning_customer_revenue]).to eq(200.0)
    end
  end

  describe "rfm_segments" do
    it "ranks customers into quintile-based segments — best-on-all-3-dimensions as Campeões, worst as Perdidos" do
      # 5 customers, strictly increasing recency/frequency/monetary in lockstep
      # (no ties) so NTILE(5) assigns a fully deterministic 1..5 spread on
      # every dimension — customer1 is worst on R, F and M; customer5 is best.
      make_order(yampi, email: "c1@ex.com", ordered_at: 200.days.ago, gross: 10)

      make_order(yampi, email: "c2@ex.com", ordered_at: 150.days.ago, gross: 20)
      make_order(yampi, email: "c2@ex.com", ordered_at: 140.days.ago, gross: 20)

      make_order(yampi, email: "c3@ex.com", ordered_at: 100.days.ago, gross: 30)
      make_order(yampi, email: "c3@ex.com", ordered_at: 95.days.ago,  gross: 30)
      make_order(yampi, email: "c3@ex.com", ordered_at: 90.days.ago,  gross: 30)

      make_order(yampi, email: "c4@ex.com", ordered_at: 50.days.ago, gross: 40)
      make_order(yampi, email: "c4@ex.com", ordered_at: 45.days.ago, gross: 40)
      make_order(yampi, email: "c4@ex.com", ordered_at: 40.days.ago, gross: 40)
      make_order(yampi, email: "c4@ex.com", ordered_at: 35.days.ago, gross: 40)

      make_order(yampi, email: "c5@ex.com", ordered_at: 10.days.ago, gross: 100)
      make_order(yampi, email: "c5@ex.com", ordered_at: 8.days.ago,  gross: 100)
      make_order(yampi, email: "c5@ex.com", ordered_at: 6.days.ago,  gross: 100)
      make_order(yampi, email: "c5@ex.com", ordered_at: 4.days.ago,  gross: 100)
      make_order(yampi, email: "c5@ex.com", ordered_at: 2.days.ago,  gross: 100)

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(channel: "yampi"))
      segments = result[:rfm_segments].index_by { |s| s[:segment] }

      # customer4 (r=4,f=4,m=4) and customer5 (r=5,f=5,m=5) both clear the
      # ">= 4 on all three" Campeões bar.
      expect(segments["Campeões"][:customers_count]).to eq(2)
      expect(segments["Campeões"][:total_revenue]).to eq(660.0) # 4*40 + 5*100

      # customer1 (r=1,f=1) and customer2 (r=2,f=2) both clear "<= 2 on R and F".
      expect(segments["Perdidos"][:customers_count]).to eq(2)
      expect(segments["Perdidos"][:total_revenue]).to eq(50.0) # 10 + 2*20

      expect(result[:rfm_segments].first[:segment]).to eq("Campeões") # sorted by revenue desc
    end

    it "returns an empty array when no orders have a captured email" do
      make_order(yampi, email: nil, ordered_at: 1.day.ago, gross: 100)

      result = described_class.call(tenant: tenant, params: ActionController::Parameters.new(channel: "yampi"))
      expect(result[:rfm_segments]).to eq([])
    end
  end
end
