class AddIdworksFieldsToOrders < ActiveRecord::Migration[7.2]
  def change
    add_column :orders, :real_freight_cost, :decimal, precision: 10, scale: 2
    add_column :orders, :tax_amount, :decimal, precision: 10, scale: 2
  end
end
