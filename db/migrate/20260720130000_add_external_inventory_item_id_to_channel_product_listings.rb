class AddExternalInventoryItemIdToChannelProductListings < ActiveRecord::Migration[7.2]
  def change
    add_column :channel_product_listings, :external_inventory_item_id, :string
  end
end
