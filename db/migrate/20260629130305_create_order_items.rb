class CreateOrderItems < ActiveRecord::Migration[7.2]
  def change
    create_table :order_items do |t|
      t.references :order, null: false, foreign_key: true
      t.references :product, null: true, foreign_key: true
      t.string :sku
      t.string :name
      t.integer :quantity, default: 1
      t.decimal :unit_price, precision: 10, scale: 2
      t.decimal :unit_cost, precision: 10, scale: 2
      t.decimal :discount, precision: 10, scale: 2, default: 0
      t.timestamps
    end
  end
end
