class ShopAnalyticsSnapshot < ApplicationRecord
  belongs_to :tenant
  belongs_to :channel

  validates :period_start, :period_end, presence: true
  validate :period_end_not_before_period_start

  scope :covering, ->(from, to) { where("period_start <= ? AND period_end >= ?", to, from) }

  private

  def period_end_not_before_period_start
    return if period_start.blank? || period_end.blank?

    errors.add(:period_end, "não pode ser anterior a period_start") if period_end < period_start
  end
end
