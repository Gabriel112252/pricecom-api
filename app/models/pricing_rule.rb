class PricingRule < ApplicationRecord
  belongs_to :product
  belongs_to :channel

  validates :target_margin_pct, presence: true
  validates :product_id, uniqueness: { scope: :channel_id }

  def calculate!
    op_cost = ChannelOperationalCost.find_by(product: product, channel: channel)&.cost || 0
    commission = channel.commission_pct / 100.0
    margin = target_margin_pct / 100.0

    base = product.cost_price + op_cost
    price = base / (1.0 - margin - commission)

    update!(
      suggested_price: price.round(2),
      last_calculated_at: Time.current
    )
  end
end
