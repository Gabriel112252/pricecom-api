class ProductRegistrationPublication < ApplicationRecord
  CHANNELS = %w[shopify yampi tiktok nuvemshop idworks].freeze
  STATUSES = %w[planned publishing published failed waiting_connector].freeze

  belongs_to :product_registration, inverse_of: :publications

  validates :channel, presence: true, inclusion: { in: CHANNELS }
  validates :channel, uniqueness: { scope: :product_registration_id }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
