class Order < ApplicationRecord
  belongs_to :tenant
  belongs_to :channel
  has_many :order_items,        dependent: :destroy
  has_many :integration_mappings, as: :mappable, dependent: :nullify

  before_save :calculate_margin

  scope :active, -> { where.not(status: "Cancelado") }

  def calculate_margin
    self.margin = gross_value - cost_price - freight - discount - commission - operational_cost
    self.margin_pct = gross_value > 0 ? (margin / gross_value * 100).round(2) : 0
  end
end
