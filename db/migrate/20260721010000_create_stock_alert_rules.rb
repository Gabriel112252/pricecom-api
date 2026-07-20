class CreateStockAlertRules < ActiveRecord::Migration[7.2]
  def change
    create_table :stock_alert_rules do |t|
      t.references :tenant, null: false, foreign_key: true
      t.references :product, null: false, foreign_key: true
      t.string :channel, null: false
      t.decimal :min_threshold, precision: 12, scale: 3, null: false, default: 0
      t.decimal :target_level, precision: 12, scale: 3, null: false
      t.string :automation_level, null: false, default: "manual"
      t.boolean :active, default: true, null: false

      t.timestamps
    end

    add_index :stock_alert_rules, [ :tenant_id, :product_id, :channel ], unique: true
  end
end
