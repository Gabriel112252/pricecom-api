class CreateChannelProductListings < ActiveRecord::Migration[7.2]
  def change
    create_table :channel_product_listings do |t|
      t.references :product, null: false, foreign_key: true
      t.references :tenant, null: false, foreign_key: true
      t.string :channel, null: false
      t.string :external_id
      t.string :external_sku
      t.decimal :stock_qty, precision: 12, scale: 3
      t.decimal :price, precision: 10, scale: 2
      t.jsonb :raw_payload, default: {}
      t.datetime :synced_at

      t.timestamps
    end

    add_index :channel_product_listings, [:tenant_id, :channel, :external_id], unique: true
  end
end
