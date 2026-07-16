class Order < ApplicationRecord
  belongs_to :tenant
  belongs_to :channel
  has_many :order_items,          dependent: :destroy
  has_many :order_refunds,        dependent: :destroy
  has_many :audit_conflicts,      dependent: :destroy
  has_many :financial_settlement_items, dependent: :nullify
  has_many :financial_receivables, dependent: :nullify
  has_many :integration_mappings, as: :mappable, dependent: :nullify
  has_many :converted_carts, class_name: "Cart", foreign_key: :converted_order_id,
    dependent: :nullify, inverse_of: :converted_order

  ORDER_TYPES = %w[sale refund cancellation exchange].freeze

  validates :order_type, inclusion: { in: ORDER_TYPES }

  before_save :calculate_margin

  scope :active,       -> { where.not(status: "Cancelado") }
  scope :sales,        -> { where(order_type: "sale") }
  scope :cancellations, -> { where(order_type: "cancellation") }
  scope :refunds,      -> { where(order_type: "refund") }

  # margin_pct e a coluna decimal(5,2): valores fora de +-999.99 estouram o insert
  MARGIN_PCT_RANGE = (-999.99..999.99)

  def calculate_margin
    self.margin = gross_value.to_f - cost_price.to_f - effective_freight_cost - discount.to_f - commission.to_f - operational_cost.to_f - effective_tax_amount
    self.margin_pct = gross_value.to_f > 0 ? (margin / gross_value.to_f * 100).round(2).clamp(MARGIN_PCT_RANGE.min, MARGIN_PCT_RANGE.max) : 0
  end

  def net_gross_value
    (gross_value.to_f - refund_amount.to_f).round(2)
  end

  def net_margin
    (margin.to_f - refund_amount.to_f).round(2)
  end

  def net_margin_pct
    return 0.0 unless gross_value.to_f > 0
    (net_margin / gross_value.to_f * 100).round(2).clamp(MARGIN_PCT_RANGE.min, MARGIN_PCT_RANGE.max)
  end

  # Fontes cujo custo real de frete é persistido em real_freight_cost —
  # idworks (sync do ERP) e lucrofrete (pedidos casados pelo parceiro, ver
  # Integrations::Lucrofrete::OrdersSyncService).
  REAL_FREIGHT_COST_SOURCES = %w[idworks lucrofrete].freeze

  def effective_freight_cost
    REAL_FREIGHT_COST_SOURCES.include?(DataSourceConfig.source_for(tenant, "freight")) ? real_freight_cost.to_f : freight.to_f
  end

  def effective_tax_amount
    DataSourceConfig.source_for(tenant, "tax").present? ? tax_amount.to_f : 0.0
  end
end
