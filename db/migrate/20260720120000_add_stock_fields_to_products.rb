class AddStockFieldsToProducts < ActiveRecord::Migration[7.2]
  def change
    add_column :products, :qty_available, :decimal, precision: 12, scale: 3, default: "0.0"
    add_column :products, :qty_reserved, :decimal, precision: 12, scale: 3, default: "0.0"
    add_column :products, :qty_safety_stock, :decimal, precision: 12, scale: 3
    add_column :products, :abc_curve, :string
    add_column :products, :lead_time_days, :integer, default: 0
    add_column :products, :infinite_inventory, :boolean, default: false, null: false
    add_column :products, :stock_synced_at, :datetime

    add_index :products, [ :tenant_id, :abc_curve ]
    add_index :products, :qty_available
  end
end
