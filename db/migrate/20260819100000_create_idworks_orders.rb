class CreateIdworksOrders < ActiveRecord::Migration[7.2]
  def change
    create_table :idworks_orders do |t|
      t.references :tenant,      null: false, foreign_key: true
      t.references :integration, null: false, foreign_key: true

      # IDOrder is the stable identifier from the ERP. It is deliberately
      # scoped to an integration because two IDWorks companies can reuse it.
      t.string  :external_id,         null: false
      t.string  :order_number
      t.datetime :recorded_at
      t.string  :status_order
      t.integer :id_status_order
      t.string  :sales_channel_slug
      t.decimal :value_shipping,      precision: 12, scale: 2
      t.decimal :value_product,       precision: 12, scale: 2
      t.decimal :value_order,         precision: 12, scale: 2
      t.decimal :value_paid,          precision: 12, scale: 2
      t.datetime :last_seen_at,       null: false

      t.timestamps
    end

    add_index :idworks_orders, [:integration_id, :external_id], unique: true,
              name: "idx_idworks_orders_on_integration_external"
    add_index :idworks_orders, [:tenant_id, :recorded_at]
    add_index :idworks_orders, [:tenant_id, :sales_channel_slug]
  end
end
