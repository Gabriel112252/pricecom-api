class AddSellerAndPlatformDiscountToOrders < ActiveRecord::Migration[7.2]
  def change
    # TikTok Shop's payment object splits the order discount into
    # seller_discount (funded by the seller, reduces their margin) and
    # platform_discount (funded by TikTok itself, must NOT reduce the
    # seller's margin). orders.discount used to be seller_discount +
    # platform_discount combined, overstating the discount subtracted in
    # Order#calculate_margin. orders.discount now holds seller_discount
    # only going forward; seller_discount is kept as an explicit column for
    # clarity, platform_discount is audit-only and excluded from margin.
    add_column :orders, :seller_discount,   :decimal, precision: 10, scale: 2, default: 0, null: false
    add_column :orders, :platform_discount, :decimal, precision: 10, scale: 2, default: 0, null: false
  end
end
