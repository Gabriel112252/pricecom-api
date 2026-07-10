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

  validates :sku, presence: true, uniqueness: { scope: :tenant_id }
  validates :name, presence: true
end
