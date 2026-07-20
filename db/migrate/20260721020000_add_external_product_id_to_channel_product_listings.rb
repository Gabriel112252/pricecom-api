class AddExternalProductIdToChannelProductListings < ActiveRecord::Migration[7.2]
  def change
    add_column :channel_product_listings, :external_product_id, :string
  end
end
