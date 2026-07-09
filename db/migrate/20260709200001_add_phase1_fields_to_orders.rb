class AddPhase1FieldsToOrders < ActiveRecord::Migration[7.2]
  def change
    add_column :orders, :order_type,    :string,  default: "sale", null: false
    add_column :orders, :refund_amount, :decimal, precision: 10, scale: 2, default: "0.0", null: false
    add_column :orders, :nf_number,     :string
    add_column :orders, :nf_gross_value, :decimal, precision: 10, scale: 2, default: "0.0", null: false
    add_column :orders, :nf_discount,   :decimal, precision: 10, scale: 2, default: "0.0", null: false
    add_column :orders, :nf_freight,    :decimal, precision: 10, scale: 2, default: "0.0", null: false

    add_index :orders, [:tenant_id, :order_type], name: "index_orders_on_tenant_id_and_order_type"
  end
end
