# One low-stock event for a tenant/product/channel. See
# StockAlerts::EvaluationService (creates/refreshes these) and
# StockAlerts::ReplenishmentExecutorService (executes the replenishment
# for a "pending"/"awaiting_confirmation" alert).
class StockAlert < ApplicationRecord
  belongs_to :tenant
  belongs_to :product
  belongs_to :stock_alert_rule, optional: true

  # skipped_duplicate is reserved for a future stricter de-duplication
  # strategy — StockAlerts::EvaluationService currently refreshes the
  # existing open alert in place instead of ever producing this status
  # (see that class's comment). dismissed is set only by the
  # POST .../dismiss endpoint (a human explicitly said "not now"), distinct
  # from skipped_duplicate (the system declining to create a second alert).
  STATUSES = %w[
    pending awaiting_confirmation executed failed insufficient_reserve
    skipped_duplicate dismissed
  ].freeze

  # "Open" = not yet resolved one way or another. insufficient_reserve
  # counts as open because StockAlerts::EvaluationService.
  # reevaluate_insufficient_reserves re-checks these once qty_available
  # changes — the alert isn't done, it's just waiting on more stock.
  OPEN_STATUSES = %w[pending awaiting_confirmation insufficient_reserve].freeze

  validates :channel, presence: true, inclusion: { in: StockAlertRule::CHANNELS }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :qty_at_trigger, :target_level, :suggested_replenishment_qty, presence: true
  validates :automation_level_snapshot, presence: true, inclusion: { in: StockAlertRule::AUTOMATION_LEVELS }

  scope :open, -> { where(status: OPEN_STATUSES) }

  def open? = OPEN_STATUSES.include?(status)
end
