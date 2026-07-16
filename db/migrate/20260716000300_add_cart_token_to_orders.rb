class AddCartTokenToOrders < ActiveRecord::Migration[7.2]
  def change
    add_column :orders, :cart_token, :string
    add_index :orders, [ :tenant_id, :cart_token ]
  end
end
