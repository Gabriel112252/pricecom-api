class CreateReconciliationItems < ActiveRecord::Migration[7.2]
  def change
    create_table :reconciliation_items do |t|
      t.references :tenant,      null: false, foreign_key: true
      t.references :integration, null: true,  foreign_key: true
      t.references :product,     null: true,  foreign_key: true

      t.date :period_start, null: false
      t.date :period_end,   null: false

      t.string :sku,          null: false
      t.string :product_name

      t.decimal :idworks_qty,  precision: 12, scale: 3, default: "0.0", null: false
      t.decimal :pricecom_qty, precision: 12, scale: 3, default: "0.0", null: false
      t.decimal :diff_qty,     precision: 12, scale: 3, default: "0.0", null: false
      t.decimal :diff_pct,     precision: 10, scale: 2

      t.timestamps
    end

    add_index :reconciliation_items, [:tenant_id, :sku, :period_start, :period_end],
              unique: true, name: "idx_reconciliation_items_on_tenant_sku_period"
    add_index :reconciliation_items, [:tenant_id, :period_start, :period_end],
              name: "idx_reconciliation_items_on_tenant_period"
  end
end
