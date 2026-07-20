class CreateStockAlerts < ActiveRecord::Migration[7.2]
  def change
    create_table :stock_alerts do |t|
      t.references :tenant, null: false, foreign_key: true
      t.references :product, null: false, foreign_key: true
      # Nullable on purpose (a rule can be deleted after it already fired
      # alerts) — on_delete: :nullify so deleting a StockAlertRule detaches
      # its past alerts instead of being blocked by the FK or cascading a
      # delete into alert history.
      t.references :stock_alert_rule, foreign_key: { on_delete: :nullify }
      t.string :channel, null: false
      t.decimal :qty_at_trigger, precision: 12, scale: 3, null: false
      t.decimal :target_level, precision: 12, scale: 3, null: false
      t.decimal :suggested_replenishment_qty, precision: 12, scale: 3, null: false
      t.string :automation_level_snapshot, null: false
      t.string :status, null: false, default: "pending"
      # pending | awaiting_confirmation | executed | failed |
      # insufficient_reserve | skipped_duplicate | dismissed
      t.text :error_message
      t.datetime :executed_at

      t.timestamps
    end

    add_index :stock_alerts, [ :tenant_id, :product_id, :channel, :status ]
  end
end
