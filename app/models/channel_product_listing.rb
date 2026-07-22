class ChannelProductListing < ApplicationRecord
  # Fase 2 of the stock/alerts migration — normalized selling state, one
  # vocabulary across Shopify/TikTok/Yampi's very different raw status
  # strings. See each adapter's #normalize_selling_status for the mapping
  # from raw channel status to this. "unknown" (the column default) means
  # no sync has populated it yet, not a real channel state — never treated
  # as eligible.
  SELLING_STATUSES = %w[selling draft inactive reviewing rejected platform_blocked deleted unknown].freeze

  # How long remote_status can go un-refreshed before it's treated as
  # untrustworthy for a real-time decision (replenishment eligibility).
  # Every channel's product sync runs at least every 15min in the healthy
  # case (config/schedule.yml) — 6h is a generous multiple of that,
  # matching the "something is actually wrong" cadence this codebase
  # already uses elsewhere for a slow-but-not-urgent signal (idworks'
  # product_cost_sync_dispatch is also every 6h).
  STATUS_STALE_AFTER = 6.hours

  belongs_to :tenant
  belongs_to :product
  has_many :stock_replenishment_executions, dependent: :destroy

  validates :channel, presence: true, inclusion: { in: ChannelCredential::CHANNELS }
  validates :external_id, presence: true, uniqueness: { scope: [ :tenant_id, :channel ] }
  # Lower = higher priority. Nullable (most listings have none set yet —
  # see the migration) — see StockAlerts::EvaluationService#resolve_target
  # for how this picks the channel a low-pool alert replenishes.
  validates :channel_priority, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :selling_status, presence: true, inclusion: { in: SELLING_STATUSES }

  scope :for_channel, ->(channel) { where(channel: channel) }
  scope :stale, ->(before) { where("synced_at < ?", before) }
  scope :replenishment_eligible, -> { where(replenishment_eligible: true) }

  # Deliberately computed on read, not a stored column: a persisted boolean
  # here would itself need a background job just to stay accurate as time
  # passes with no new sync — computing it from remote_status_synced_at
  # can never go stale itself.
  def status_stale?
    remote_status_synced_at.nil? || remote_status_synced_at < STATUS_STALE_AFTER.ago
  end
end
