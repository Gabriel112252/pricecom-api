# One row per product (see the Fase 2 migration
# ConsolidateStockAlertRulesToProduct) — no longer per product+channel.
# `channel` is still a physical column (kept nullable on purpose, for easy
# rollback) but is no longer read or written here; StockAlerts::
# EvaluationService resolves which channel to replenish from
# ChannelProductListing#channel_priority instead.
class StockAlertRule < ApplicationRecord
  belongs_to :tenant
  belongs_to :product
  has_many :stock_alerts, dependent: :nullify
  has_many :stock_replenishment_executions, dependent: :destroy

  # Still the whitelist of channels StockAlert#channel (informational) and
  # ReplenishmentExecutorService can target — unrelated to this model no
  # longer having its own channel.
  CHANNELS = %w[yampi shopify tiktok].freeze
  AUTOMATION_LEVELS = %w[manual semi_automatic automatic].freeze

  validates :product_id, uniqueness: { scope: :tenant_id }
  validates :automation_level, presence: true, inclusion: { in: AUTOMATION_LEVELS }
  validates :min_threshold, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :target_level, presence: true, numericality: { greater_than: 0 }

  scope :active, -> { where(active: true) }

  # No longer validates target_level > min_threshold: since Fase 2,
  # min_threshold is compared against Product#free_reserve (the whole
  # pool) while target_level is the desired stock level for a single
  # channel (whichever has the lowest channel_priority — see
  # StockAlerts::EvaluationService) — two different quantities on two
  # different scales that just happen to share a table. A pool
  # min_threshold of 500 units and a single channel's target_level of 50
  # units is a perfectly sane configuration that the old per-channel
  # validation would have wrongly rejected.
end
