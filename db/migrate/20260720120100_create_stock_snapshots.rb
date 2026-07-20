class CreateStockSnapshots < ActiveRecord::Migration[7.2]
  def change
    create_table :stock_snapshots do |t|
      t.references :tenant, null: false, foreign_key: true
      t.references :product, null: false, foreign_key: true
      t.decimal :qty_available, precision: 12, scale: 3
      t.decimal :qty_reserved, precision: 12, scale: 3
      t.decimal :qty_safety_stock, precision: 12, scale: 3
      t.string :abc_curve
      t.integer :lead_time_days
      t.boolean :infinite_inventory, default: false, null: false
      t.datetime :synced_at, null: false
      t.jsonb :raw_payload, default: {}, null: false

      t.timestamps
    end

    add_index :stock_snapshots, [ :tenant_id, :product_id, :synced_at ]
  end
end
