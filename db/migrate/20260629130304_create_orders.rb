class CreateOrders < ActiveRecord::Migration[7.2]
  def change
    create_table :orders do |t|
      t.references :tenant, null: false, foreign_key: true
      t.references :channel, null: false, foreign_key: true
      t.string :external_id
      t.string :order_number
      t.decimal :gross_value, precision: 10, scale: 2, default: 0
      t.decimal :cost_price, precision: 10, scale: 2, default: 0
      t.decimal :freight, precision: 10, scale: 2, default: 0
      t.decimal :discount, precision: 10, scale: 2, default: 0
      t.decimal :commission, precision: 10, scale: 2, default: 0
      t.decimal :operational_cost, precision: 10, scale: 2, default: 0
      t.decimal :margin, precision: 10, scale: 2
      t.decimal :margin_pct, precision: 5, scale: 2
      t.string :status
      t.string :payment_method
      t.string :customer_name
      t.string :customer_tag
      t.string :state
      t.decimal :weight_kg, precision: 8, scale: 3
      t.integer :items_qty, default: 1
      t.datetime :ordered_at
      t.timestamps
    end
    add_index :orders, [:tenant_id, :external_id]
    add_index :orders, [:tenant_id, :ordered_at]
  end
end
