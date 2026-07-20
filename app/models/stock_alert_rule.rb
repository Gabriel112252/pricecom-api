class StockAlertRule < ApplicationRecord
  belongs_to :tenant
  belongs_to :product
  has_many :stock_alerts, dependent: :nullify

  CHANNELS = %w[yampi shopify tiktok].freeze
  AUTOMATION_LEVELS = %w[manual semi_automatic automatic].freeze

  validates :channel, presence: true, inclusion: { in: CHANNELS }
  validates :product_id, uniqueness: { scope: [ :tenant_id, :channel ] }
  validates :automation_level, presence: true, inclusion: { in: AUTOMATION_LEVELS }
  validates :min_threshold, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :target_level, presence: true, numericality: { greater_than: 0 }
  validate :target_level_above_min_threshold

  scope :active, -> { where(active: true) }

  private

  def target_level_above_min_threshold
    return if target_level.blank? || min_threshold.blank?

    errors.add(:target_level, "deve ser maior que min_threshold") if target_level <= min_threshold
  end
end
