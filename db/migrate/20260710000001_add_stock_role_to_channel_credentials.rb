class AddStockRoleToChannelCredentials < ActiveRecord::Migration[7.2]
  def change
    # 0 = fonte_estoque, 1 = consumidor_pedido, 2 = ambos (matches
    # ChannelCredential's enum declaration).
    add_column :channel_credentials, :role, :integer, default: 2, null: false

    add_reference :channel_credentials, :stock_source_channel,
                   foreign_key: { to_table: :channel_credentials }, null: true

    # Idempotency guard for Integrations::OrderStockDeductionService — an
    # order can be re-upserted many times (webhook retries, status
    # updates), but stock must only ever be debited once per order.
    add_column :orders, :stock_deducted_at, :datetime
  end
end
