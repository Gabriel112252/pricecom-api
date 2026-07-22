# One low-stock event for a tenant/product — see
# StockAlerts::EvaluationService (creates/refreshes these, edge-triggered
# on a threshold crossing) and StockAlerts::CreateReplenishmentExecution +
# StockAlerts::ExecuteReplenishmentJob (the async pipeline that actually
# replenishes a channel for a "pending"/"awaiting_confirmation" alert — see
# StockReplenishmentExecution for the attempt-level history).
#
# `channel` is informational only since Fase 2 (the product-level stock
# migration): it records which channel EvaluationService resolved as the
# replenishment target (ChannelProductListing#channel_priority) at the
# moment this alert fired, not part of the alert's identity — one open
# alert per product now, not per product+channel (see #open scope callers
# in EvaluationService#upsert_alert). Nullable: a product can be below
# min_threshold with no priority channel configured yet, in which case
# there's nothing to target.
class StockAlert < ApplicationRecord
  belongs_to :tenant
  belongs_to :product
  belongs_to :stock_alert_rule, optional: true
  has_many :stock_replenishment_executions, dependent: :nullify

  # skipped_duplicate is reserved for a future stricter de-duplication
  # strategy — StockAlerts::EvaluationService currently refreshes the
  # existing open alert in place instead of ever producing this status
  # (see that class's comment). dismissed is set only by the
  # POST .../dismiss endpoint (a human explicitly said "not now"), distinct
  # from skipped_duplicate (the system declining to create a second alert).
  # resolved is set by EvaluationService when free_reserve recovers above
  # min_threshold on its own — distinct from executed (a replenishment
  # actually ran): the pool can recover from an idworks sync or a channel
  # sale reducing that channel's own allocation, with no replenishment
  # involved at all.
  STATUSES = %w[
    pending awaiting_confirmation executed failed insufficient_reserve
    skipped_duplicate dismissed resolved
  ].freeze

  # "Open" = not yet resolved one way or another. insufficient_reserve
  # counts as open because StockAlerts::EvaluationService re-checks these
  # every time it runs (event-driven — see that class) — the alert isn't
  # done, it's just waiting on more stock. This is also the signal
  # EvaluationService uses to detect a threshold crossing (edge-triggered):
  # no open alert for this product == the pool was fine as of the last
  # evaluation, so a fresh "below min_threshold" reading is a real crossing,
  # not a repeat of one already being handled.
  OPEN_STATUSES = %w[pending awaiting_confirmation insufficient_reserve].freeze

  validates :channel, inclusion: { in: StockAlertRule::CHANNELS }, allow_nil: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :qty_at_trigger, :target_level, :suggested_replenishment_qty, presence: true
  validates :automation_level_snapshot, presence: true, inclusion: { in: StockAlertRule::AUTOMATION_LEVELS }

  scope :open, -> { where(status: OPEN_STATUSES) }

  def open? = OPEN_STATUSES.include?(status)
end
