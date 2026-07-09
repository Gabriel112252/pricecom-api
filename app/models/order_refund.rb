class OrderRefund < ApplicationRecord
  belongs_to :tenant
  belongs_to :order
  belongs_to :integration, optional: true

  STATUSES = %w[pending processed ignored error].freeze

  validates :amount, numericality: { greater_than_or_equal_to: 0 }
  validates :status, inclusion: { in: STATUSES }

  scope :pending,   -> { where(status: "pending") }
  scope :processed, -> { where(status: "processed") }
  scope :recent,    -> { order(refunded_at: :desc, created_at: :desc) }
end
