class Order < ApplicationRecord
  belongs_to :tenant
  belongs_to :channel
  has_many :order_items,          dependent: :destroy
  has_many :order_refunds,        dependent: :destroy
  has_many :integration_mappings, as: :mappable, dependent: :nullify

  ORDER_TYPES = %w[sale refund cancellation exchange].freeze

  validates :order_type, inclusion: { in: ORDER_TYPES }

  before_save :calculate_margin

  scope :active,       -> { where.not(status: "Cancelado") }
  scope :sales,        -> { where(order_type: "sale") }
  scope :cancellations, -> { where(order_type: "cancellation") }
  scope :refunds,      -> { where(order_type: "refund") }

  def calculate_margin
    self.margin = gross_value - cost_price - freight - discount - commission - operational_cost
    self.margin_pct = gross_value > 0 ? (margin / gross_value * 100).round(2) : 0
  end

  def net_gross_value
    (gross_value.to_f - refund_amount.to_f).round(2)
  end

  def net_margin
    (margin.to_f - refund_amount.to_f).round(2)
  end

  def net_margin_pct
    return 0.0 unless gross_value.to_f > 0
    (net_margin / gross_value.to_f * 100).round(2)
  end
end
