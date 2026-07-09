class CreateProducts < ActiveRecord::Migration[7.2]
  def change
    create_table :products do |t|
      t.references :tenant, null: false, foreign_key: true
      t.string :sku, null: false
      t.string :name, null: false
      t.decimal :cost_price, precision: 10, scale: 2, default: 0
      t.string :idworks_id
      t.boolean :active, default: true
      t.timestamps
    end
    add_index :products, [:tenant_id, :sku], unique: true
  end
end
