class CreateLucrofreteOrderReports < ActiveRecord::Migration[7.2]
  def change
    create_table :lucrofrete_order_reports do |t|
      t.references :tenant, null: false, foreign_key: true
      t.references :channel, null: false, foreign_key: true
      t.references :order, foreign_key: true

      # Payload "id" from /api/reports/orders. Kept with an explicit name
      # because Rails already owns the primary-key "id" column.
      t.string :lucrofrete_order_id, null: false
      t.string :shopify_order_id
      t.string :order_number, null: false
      t.datetime :order_created_at
      t.string :customer_state
      t.string :customer_city
      t.string :customer_zipcode
      t.decimal :total_order_value, precision: 12, scale: 2
      t.integer :total_items
      t.decimal :freight_charged, precision: 12, scale: 2
      t.decimal :freight_cost, precision: 12, scale: 2
      t.decimal :margin_value, precision: 12, scale: 2
      t.decimal :margin_percent, precision: 10, scale: 2
      t.boolean :is_free_shipping
      t.string :shipping_method_title
      t.string :slot_name
      t.string :carrier_name
      t.string :match_status
      t.string :quote_log_id
      t.jsonb :raw_payload, default: {}, null: false
      t.datetime :synced_at

      t.timestamps
    end

    add_index :lucrofrete_order_reports, [ :tenant_id, :lucrofrete_order_id ], unique: true, name: "idx_lucrofrete_reports_tenant_lf_id"
    add_index :lucrofrete_order_reports, [ :tenant_id, :channel_id, :order_number ], name: "idx_lucrofrete_reports_tenant_channel_order"
    add_index :lucrofrete_order_reports, [ :tenant_id, :order_created_at ], name: "idx_lucrofrete_reports_tenant_created_at"
    add_index :lucrofrete_order_reports, [ :tenant_id, :match_status ], name: "idx_lucrofrete_reports_tenant_match_status"
    add_index :lucrofrete_order_reports, :quote_log_id
  end
end
