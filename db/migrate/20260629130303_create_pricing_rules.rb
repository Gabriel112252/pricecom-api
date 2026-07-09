class CreatePricingRules < ActiveRecord::Migration[7.2]
  def change
    create_table :pricing_rules do |t|
      t.references :product, null: false, foreign_key: true
      t.references :channel, null: false, foreign_key: true
      t.decimal :target_margin_pct, precision: 5, scale: 2, default: 30
      t.decimal :suggested_price, precision: 10, scale: 2
      t.decimal :current_price, precision: 10, scale: 2
      t.datetime :last_calculated_at
      t.timestamps
    end
    add_index :pricing_rules, [:product_id, :channel_id], unique: true
  end
end
