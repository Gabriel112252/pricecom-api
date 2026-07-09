class OrderItem < ApplicationRecord
  belongs_to :order
  belongs_to :product, optional: true

  scope :gifts,     -> { where(is_gift: true) }
  scope :non_gifts, -> { where(is_gift: false) }
end
