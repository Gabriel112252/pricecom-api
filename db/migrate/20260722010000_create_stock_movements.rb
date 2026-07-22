class CreateStockMovements < ActiveRecord::Migration[7.2]
  def change
    create_table :stock_movements do |t|
      t.references :tenant, null: false, foreign_key: true
      t.references :product, null: false, foreign_key: true
      # nil = movement on the central pool (Product#qty_available, idworks);
      # present = movement on one channel's own ChannelProductListing#stock_qty.
      t.string :channel

      t.string :kind, null: false        # entrada | saida | balanco | ajuste | sync
      t.decimal :quantity, precision: 12, scale: 3, null: false      # signed delta
      t.decimal :previous_qty, precision: 12, scale: 3, null: false
      t.decimal :new_qty, precision: 12, scale: 3, null: false

      t.string :source, null: false      # idworks_sync | channel_sync | order | manual_channel_adjust | manual_pool_adjust | replenishment
      t.references :user, null: true, foreign_key: true

      t.jsonb :metadata, null: false, default: {}

      t.datetime :created_at, null: false
    end

    add_index :stock_movements, [ :tenant_id, :product_id, :created_at ]
    add_index :stock_movements, [ :tenant_id, :channel, :created_at ]
  end
end
