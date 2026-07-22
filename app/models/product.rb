class Product < ApplicationRecord
  belongs_to :tenant
  has_many :order_items, dependent: :nullify
  has_many :pricing_rules, dependent: :destroy
  has_many :channel_operational_costs, dependent: :destroy
  has_many :audit_conflicts, dependent: :destroy

  has_many :kit_components, foreign_key: :kit_product_id, dependent: :destroy
  has_many :components, through: :kit_components, source: :component_product
  has_many :kit_memberships, foreign_key: :component_product_id, class_name: "KitComponent", dependent: :destroy

  has_many :channel_product_listings, dependent: :destroy
  has_many :stock_snapshots, dependent: :destroy
  has_many :stock_alert_rules, dependent: :destroy
  has_many :stock_alerts, dependent: :destroy
  has_many :stock_movements, dependent: :destroy
  has_many :stock_replenishment_executions, dependent: :destroy

  validates :sku, presence: true, uniqueness: { scope: :tenant_id }
  validates :name, presence: true

  # Physical stock (idworks' QtyAvailable, see qty_available's own comment
  # in the Fase 1 migration) not yet allocated to ANY sales channel —
  # qty_available already IS the ERP's total, so subtracting every
  # channel's stock_qty (including the one a StockAlert is currently
  # evaluating) isn't double-counting: it's "total minus what's already
  # spent everywhere," which is exactly the pool a replenishment can safely
  # draw from. See StockAlerts::EvaluationService for how this is used.
  def free_reserve
    qty_available.to_d - channel_product_listings.sum(:stock_qty).to_d
  end
end
