class AddKitSupportToProducts < ActiveRecord::Migration[7.2]
  def change
    add_column :products, :is_kit, :boolean, default: false, null: false

    create_table :kit_components do |t|
      t.references :kit_product,       null: false, foreign_key: { to_table: :products }
      t.references :component_product, null: false, foreign_key: { to_table: :products }
      t.decimal :quantity, precision: 10, scale: 3, default: "1.0", null: false

      t.timestamps
    end

    add_index :kit_components, [:kit_product_id, :component_product_id],
              unique: true, name: "index_kit_components_on_kit_and_component"
  end
end
