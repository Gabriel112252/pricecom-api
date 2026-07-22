# Fase 2 of the stock/alerts migration: normalized per-channel status, used
# to gate automatic replenishment (a draft/archived/blocked product must
# never get stock pushed to it just because it crossed a threshold).
#
# status_stale is deliberately NOT a column here — see
# ChannelProductListing#status_stale? for why it's computed from
# remote_status_synced_at on read instead of persisted (a stored boolean
# would itself need a background job just to stay accurate).
class AddRemoteStatusToChannelProductListings < ActiveRecord::Migration[7.2]
  def change
    add_column :channel_product_listings, :remote_status, :string
    add_column :channel_product_listings, :remote_status_reason, :string
    add_column :channel_product_listings, :remote_status_metadata, :jsonb, default: {}, null: false
    add_column :channel_product_listings, :remote_status_synced_at, :datetime
    # unknown until the next sync populates a real value (see
    # ProductSyncService) — never assume eligible/selling by default.
    add_column :channel_product_listings, :selling_status, :string, default: "unknown", null: false
    add_column :channel_product_listings, :selling_enabled, :boolean, default: false, null: false
    add_column :channel_product_listings, :replenishment_eligible, :boolean, default: false, null: false

    add_index :channel_product_listings, :selling_status
    add_index :channel_product_listings, [ :tenant_id, :replenishment_eligible ]
  end
end
