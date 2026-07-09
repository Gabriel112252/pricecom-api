class CreateOrderRefunds < ActiveRecord::Migration[7.2]
  def change
    create_table :order_refunds do |t|
      t.references :tenant,      null: false, foreign_key: true
      t.references :order,       null: false, foreign_key: true
      t.references :integration, null: true,  foreign_key: true

      t.string  :external_id
      t.decimal :amount,      precision: 10, scale: 2, default: "0.0", null: false
      t.string  :reason
      t.string  :status,      default: "pending", null: false
      t.datetime :refunded_at
      t.jsonb   :metadata,    default: {}, null: false

      t.timestamps
    end

    add_index :order_refunds, [:tenant_id, :external_id],
              name: "index_order_refunds_on_tenant_id_and_external_id"
    add_index :order_refunds, :status,
              name: "index_order_refunds_on_status"
    add_index :order_refunds, :refunded_at,
              name: "index_order_refunds_on_refunded_at"
  end
end
