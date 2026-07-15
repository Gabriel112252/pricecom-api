class Order < ApplicationRecord
  belongs_to :tenant
  belongs_to :channel
  has_many :order_items,          dependent: :destroy
  has_many :order_refunds,        dependent: :destroy
  has_many :audit_conflicts,      dependent: :destroy
  has_many :financial_settlement_items, dependent: :nullify
  has_many :financial_receivables, dependent: :nullify
  has_many :integration_mappings, as: :mappable, dependent: :nullify

  ORDER_TYPES = %w[sale refund cancellation exchange].freeze

  validates :order_type, inclusion: { in: ORDER_TYPES }

  before_save :calculate_margin

  scope :active,       -> { where.not(status: "Cancelado") }
  scope :sales,        -> { where(order_type: "sale") }
  scope :cancellations, -> { where(order_type: "cancellation") }
  scope :refunds,      -> { where(order_type: "refund") }

  def calculate_margin
    self.margin = gross_value.to_f - cost_price.to_f - effective_freight_cost - discount.to_f - commission.to_f - operational_cost.to_f - effective_tax_amount
    self.margin_pct = gross_value.to_f > 0 ? (margin / gross_value.to_f * 100).round(2) : 0
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

  def effective_freight_cost
    DataSourceConfig.source_for(tenant, "freight") == "idworks" ? real_freight_cost.to_f : freight.to_f
  end

  def effective_tax_amount
    DataSourceConfig.source_for(tenant, "tax").present? ? tax_amount.to_f : 0.0
  end
end
