class AddFinancialFieldsToOrders < ActiveRecord::Migration[7.2]
  def change
    # Generic order-level finance fields shared by TikTok now and Yampi later.
    add_column :orders, :revenue_amount,                :decimal, precision: 12, scale: 2, default: 0, null: false
    add_column :orders, :settlement_amount,             :decimal, precision: 12, scale: 2, default: 0, null: false
    add_column :orders, :fee_and_tax_amount,            :decimal, precision: 12, scale: 2, default: 0, null: false
    add_column :orders, :shipping_cost_amount,          :decimal, precision: 12, scale: 2, default: 0, null: false
    add_column :orders, :platform_commission_amount,    :decimal, precision: 12, scale: 2, default: 0, null: false
    add_column :orders, :affiliate_commission_amount,   :decimal, precision: 12, scale: 2, default: 0, null: false
    add_column :orders, :item_fee_amount,               :decimal, precision: 12, scale: 2, default: 0, null: false
    add_column :orders, :service_fee_amount,            :decimal, precision: 12, scale: 2, default: 0, null: false
    add_column :orders, :financial_breakdown,           :jsonb,   default: {}, null: false
    add_column :orders, :financial_synced_at,           :datetime
    add_index :orders, [ :channel_id, :financial_synced_at ],
              name: "index_orders_on_channel_and_financial_synced_at"
  end
end
