# One replenishment attempt (automatic, on a threshold crossing, or human-
# confirmed from an "awaiting_confirmation" StockAlert) — see
# StockAlerts::CreateReplenishmentExecution (creates these, one per
# crossing/confirmation episode) and StockAlerts::ExecuteReplenishmentJob
# (the async job that does the real remote write to the channel and
# finishes the row). Never written to synchronously from a request or from
# inside OrderStockDeductionService's row lock — see both of those for why.
class StockReplenishmentExecution < ApplicationRecord
  belongs_to :tenant
  belongs_to :product
  belongs_to :channel_product_listing
  belongs_to :stock_alert_rule
  belongs_to :stock_alert, optional: true

  TRIGGER_TYPES = %w[minimum_threshold_reached].freeze
  STATUSES = %w[pending executing succeeded failed skipped].freeze
  IN_FLIGHT_STATUSES = %w[pending executing].freeze

  validates :trigger_type, presence: true, inclusion: { in: TRIGGER_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :threshold_qty, :target_qty, :previous_qty, :requested_qty, presence: true
  validates :idempotency_key, presence: true, uniqueness: true

  scope :in_flight, -> { where(status: IN_FLIGHT_STATUSES) }

  def in_flight? = IN_FLIGHT_STATUSES.include?(status)
end
