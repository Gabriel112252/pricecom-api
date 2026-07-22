# One row per replenishment attempt (automatic or human-confirmed) — see
# StockAlerts::CreateReplenishmentExecution (creates these) and
# StockAlerts::ExecuteReplenishmentJob (the async job that does the real
# remote write and finishes the row). This is the audit trail Fase 4's
# modal renders as history (executed/failed/skipped-by-ineligibility,
# total quantity replenished, last replenishment).
class CreateStockReplenishmentExecutions < ActiveRecord::Migration[7.2]
  def change
    create_table :stock_replenishment_executions do |t|
      t.references :tenant, null: false, foreign_key: true
      t.references :product, null: false, foreign_key: true
      t.references :channel_product_listing, null: false, foreign_key: true
      t.references :stock_alert_rule, null: false, foreign_key: true
      t.references :stock_alert, null: true, foreign_key: true

      t.string :trigger_type, null: false, default: "minimum_threshold_reached"
      t.string :status, null: false, default: "pending" # pending | executing | succeeded | failed | skipped

      t.decimal :threshold_qty, precision: 12, scale: 3, null: false
      t.decimal :target_qty, precision: 12, scale: 3, null: false
      t.decimal :previous_qty, precision: 12, scale: 3, null: false
      t.decimal :requested_qty, precision: 12, scale: 3, null: false
      t.decimal :confirmed_qty, precision: 12, scale: 3

      t.jsonb :remote_status_snapshot, null: false, default: {}
      t.jsonb :rule_snapshot, null: false, default: {}
      t.jsonb :remote_response, null: false, default: {}

      t.string :idempotency_key, null: false
      t.integer :attempt_count, null: false, default: 0
      t.text :error_message

      t.datetime :started_at
      t.datetime :finished_at

      t.timestamps
    end

    add_index :stock_replenishment_executions, :idempotency_key, unique: true
    add_index :stock_replenishment_executions, [ :tenant_id, :product_id, :created_at ]

    # The core idempotency guarantee (see OrderStockDeductionService and
    # StockAlerts::CreateReplenishmentExecution): at most one in-flight
    # execution per listing+rule at a time, enforced at the DB level, not
    # just in application code — a partial unique index so it still allows
    # any number of *finished* (succeeded/failed/skipped) rows for the same
    # listing+rule, just never two open ones simultaneously.
    add_index :stock_replenishment_executions,
      [ :channel_product_listing_id, :stock_alert_rule_id ],
      unique: true,
      where: "status IN ('pending', 'executing')",
      name: "idx_one_inflight_execution_per_listing_rule"
  end
end
