class AddCustomerEmailToOrders < ActiveRecord::Migration[7.2]
  def change
    add_column :orders, :customer_email, :string

    add_index :orders, [ :tenant_id, :channel_id, :customer_email ],
      name: "index_orders_on_tenant_channel_customer_email"
  end
end
