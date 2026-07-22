# Append-only ledger of every quantity change to a product's stock — either
# the central pool (Product#qty_available, channel: nil) or one channel's own
# ChannelProductListing#stock_qty (channel: present). Write-only from the
# app's perspective: nothing ever updates or destroys a row here, each write
# path just creates one record documenting what changed and why (#source).
#
# Fase 1 of the stock/alerts migration — history only, no read UI yet and no
# behavior depends on this table existing. See StockAlertRule/StockAlert for
# the per-product alerting model (Fase 2) that free_reserve/StockMovement
# eventually feed into.
class StockMovement < ApplicationRecord
  belongs_to :tenant
  belongs_to :product
  belongs_to :user, optional: true

  KINDS   = %w[entrada saida balanco ajuste sync].freeze
  SOURCES = %w[idworks_sync channel_sync order manual_channel_adjust manual_pool_adjust replenishment].freeze

  validates :kind, presence: true, inclusion: { in: KINDS }
  validates :source, presence: true, inclusion: { in: SOURCES }
  validates :quantity, :previous_qty, :new_qty, presence: true

  # #quantity is always new_qty - previous_qty — computed here once instead
  # of at each of the 5 call sites, so a caller can never log a delta with
  # the wrong sign relative to what actually happened.
  def self.record!(tenant:, product:, kind:, previous_qty:, new_qty:, source:, channel: nil, user: nil, metadata: {})
    create!(
      tenant: tenant,
      product: product,
      channel: channel,
      kind: kind,
      quantity: new_qty.to_d - previous_qty.to_d,
      previous_qty: previous_qty,
      new_qty: new_qty,
      source: source,
      user: user,
      metadata: metadata,
      created_at: Time.current
    )
  end
end
