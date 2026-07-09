class CreateChannelOperationalCosts < ActiveRecord::Migration[7.2]
  def change
    create_table :channel_operational_costs do |t|
      t.references :product, null: false, foreign_key: true
      t.references :channel, null: false, foreign_key: true
      t.decimal :cost, precision: 10, scale: 2, default: 0
      t.string :description
      t.timestamps
    end
    add_index :channel_operational_costs, [:product_id, :channel_id], unique: true
  end
end
