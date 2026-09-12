class AddTypeOrderToIdworksOrders < ActiveRecord::Migration[7.2]
  def change
    add_column :idworks_orders, :type_order, :string
    add_index :idworks_orders, [ :tenant_id, :type_order ]
  end
end
