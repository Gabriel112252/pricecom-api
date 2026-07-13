class AddCouponFieldsToOrders < ActiveRecord::Migration[7.2]
  def change
    add_column :orders, :coupon_code, :string
    add_column :orders, :coupon_discount, :decimal, precision: 10, scale: 2, null: false, default: 0

    add_index :orders, [:tenant_id, :coupon_code]
  end
end
