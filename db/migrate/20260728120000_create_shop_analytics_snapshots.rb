class CreateShopAnalyticsSnapshots < ActiveRecord::Migration[7.2]
  def change
    # One row per (tenant, channel, period) — TikTok's Get Shop Performance
    # 202405 (analytics/202405/shop/performance, see
    # TiktokAdapter#fetch_shop_analytics) returns an aggregated snapshot for
    # a date range, not per-order data, so this table mirrors that shape
    # rather than trying to force it into orders/order_items.
    #
    # gmv_live/gmv_video/gmv_product_card come from gmv_breakdowns[] keyed
    # by `type` (confirmed values: LIVE, VIDEO, PRODUCT_CARD — the new
    # content-type taxonomy TikTok is migrating Shop Analytics to, not the
    # legacy Organic/Ads split — see ShopAnalyticsSyncService). raw_response
    # keeps the full payload for audit, same convention as
    # orders.financial_breakdown.
    create_table :shop_analytics_snapshots do |t|
      t.references :tenant,  null: false, foreign_key: true
      t.references :channel, null: false, foreign_key: true

      t.date :period_start, null: false
      t.date :period_end,   null: false

      t.decimal :gmv_total,        precision: 12, scale: 2, default: 0, null: false
      t.decimal :gmv_live,         precision: 12, scale: 2, default: 0, null: false
      t.decimal :gmv_video,        precision: 12, scale: 2, default: 0, null: false
      t.decimal :gmv_product_card, precision: 12, scale: 2, default: 0, null: false
      t.decimal :refunds_amount,   precision: 12, scale: 2, default: 0, null: false

      t.integer :orders,                    default: 0, null: false
      t.integer :buyers,                    default: 0, null: false
      t.integer :product_impressions,       default: 0, null: false
      t.integer :product_page_views,        default: 0, null: false
      t.integer :cancellations_and_returns, default: 0, null: false

      t.jsonb :raw_response, default: {}, null: false
      t.datetime :synced_at, null: false

      t.timestamps
    end

    add_index :shop_analytics_snapshots, [ :tenant_id, :channel_id, :period_start, :period_end ],
      unique: true, name: "index_shop_analytics_snapshots_on_tenant_channel_period"
  end
end
