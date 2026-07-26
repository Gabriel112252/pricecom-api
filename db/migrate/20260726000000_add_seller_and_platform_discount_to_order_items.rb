class AddSellerAndPlatformDiscountToOrderItems < ActiveRecord::Migration[7.2]
  def change
    # Mirrors 20260721030000_add_seller_and_platform_discount_to_orders.rb,
    # one level down: order_items.discount kept summing seller_discount +
    # platform_discount, but order_items.unit_price (TikTok's sale_price) is
    # already net of BOTH discounts — subtracting the combined `discount`
    # from it double-counts platform_discount at the per-item/per-product
    # dashboard views. seller_discount/platform_discount give those queries
    # the same seller-only component orders.discount already has;
    # order_items.discount is left untouched for backward compatibility.
    add_column :order_items, :seller_discount,   :decimal, precision: 10, scale: 2, default: 0, null: false
    add_column :order_items, :platform_discount, :decimal, precision: 10, scale: 2, default: 0, null: false
  end
end
