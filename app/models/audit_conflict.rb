class AuditConflict < ApplicationRecord
  belongs_to :tenant
  belongs_to :order,   optional: true
  belongs_to :product, optional: true

  CONFLICT_TYPES = %w[
    missing_cost
    gift_costing_error
    nf_discount_mismatch
    nf_freight_mismatch
    refund_without_cancellation
  ].freeze

  SEVERITIES = %w[low medium high critical].freeze
  STATUSES   = %w[open resolved ignored].freeze
  SOURCES    = %w[auto manual].freeze

  validates :conflict_type, presence: true
  validates :severity, inclusion: { in: SEVERITIES }
  validates :status,   inclusion: { in: STATUSES }
  validates :source,   inclusion: { in: SOURCES }

  scope :open,     -> { where(status: "open") }
  scope :resolved, -> { where(status: "resolved") }
  scope :ignored,  -> { where(status: "ignored") }
  scope :by_type,  ->(type) { where(conflict_type: type) }
  scope :critical, -> { where(severity: "critical") }
  scope :recent,   -> { order(created_at: :desc) }
end
