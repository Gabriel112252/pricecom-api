class CreateCarts < ActiveRecord::Migration[7.2]
  def change
    create_table :carts do |t|
      t.references :tenant,  null: false, foreign_key: true
      t.references :channel, null: false, foreign_key: true
      t.string :external_id, null: false
      t.string :token
      t.string :customer_name
      t.string :customer_email

      t.decimal :subtotal,             precision: 12, scale: 2, default: "0.0", null: false
      t.decimal :discount,             precision: 12, scale: 2, default: "0.0", null: false
      t.decimal :promocode_discount,   precision: 12, scale: 2, default: "0.0", null: false
      # The cart.reminder webhook exposes progressive_discount_value where the
      # listing exposes promocode_discount_value — both are kept so the
      # dashboard can break discounts down into cupom/progressivo/combo/frete.
      t.decimal :progressive_discount, precision: 12, scale: 2, default: "0.0", null: false
      t.decimal :combos_discount,      precision: 12, scale: 2, default: "0.0", null: false
      t.decimal :shipment_discount,    precision: 12, scale: 2, default: "0.0", null: false
      t.decimal :shipment,             precision: 12, scale: 2, default: "0.0", null: false
      t.decimal :total,                precision: 12, scale: 2, default: "0.0", null: false

      t.string :status, null: false, default: "abandoned"
      t.references :converted_order, foreign_key: { to_table: :orders }
      t.datetime :abandoned_at
      t.jsonb :raw_payload, default: {}, null: false

      t.timestamps
    end

    add_index :carts, [ :tenant_id, :channel_id, :external_id ], unique: true
    add_index :carts, [ :tenant_id, :abandoned_at ]
    add_index :carts, [ :tenant_id, :status ]
    add_index :carts, :token
  end
end
