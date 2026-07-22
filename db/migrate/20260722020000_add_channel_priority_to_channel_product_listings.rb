# Lower number = higher priority. Which channel StockAlerts::
# EvaluationService replenishes when a product's pool runs low (see that
# class's #resolve_target). Starts null for every listing — there's no
# existing sales-volume data reliable enough to infer a sane default
# priority from, so this is populated manually per product/channel after
# this ships, not guessed at migration time.
class AddChannelPriorityToChannelProductListings < ActiveRecord::Migration[7.2]
  def change
    add_column :channel_product_listings, :channel_priority, :integer
    add_index :channel_product_listings, [ :tenant_id, :product_id, :channel_priority ]
  end
end
