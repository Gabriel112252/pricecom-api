# Fase 2: StockAlert lookups (StockAlerts::EvaluationService#upsert_alert)
# are now per tenant/product, not per tenant/product/channel — one open
# alert per product. `channel` stays as a column (now nullable) recording
# which channel was the replenishment target when the alert fired, purely
# informational — see StockAlert's own comment.
class MakeChannelInformationalOnStockAlerts < ActiveRecord::Migration[7.2]
  def up
    remove_index :stock_alerts, column: [ :tenant_id, :product_id, :channel, :status ]
    change_column_null :stock_alerts, :channel, true
    add_index :stock_alerts, [ :tenant_id, :product_id, :status ]
  end

  def down
    remove_index :stock_alerts, column: [ :tenant_id, :product_id, :status ]
    # Fails here if any alert was created after this shipped with no
    # priority channel configured (channel legitimately nil) — that data
    # loss (which channel, if any, is unrecoverable) is inherent to
    # rolling back past this point, not a bug in the rollback itself.
    change_column_null :stock_alerts, :channel, false
    add_index :stock_alerts, [ :tenant_id, :product_id, :channel, :status ]
  end
end
