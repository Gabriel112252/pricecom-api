class Product < ApplicationRecord
  belongs_to :tenant
  has_many :order_items, dependent: :nullify
  has_many :pricing_rules, dependent: :destroy
  has_many :channel_operational_costs, dependent: :destroy
  has_many :audit_conflicts, dependent: :destroy

  validates :sku, presence: true, uniqueness: { scope: :tenant_id }
  validates :name, presence: true
end
