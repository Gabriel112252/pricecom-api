class LucrofreteOrderReport < ApplicationRecord
  belongs_to :tenant
  belongs_to :channel
  belongs_to :order, optional: true

  validates :lucrofrete_order_id, presence: true, uniqueness: { scope: :tenant_id }
  validates :order_number, presence: true
end
