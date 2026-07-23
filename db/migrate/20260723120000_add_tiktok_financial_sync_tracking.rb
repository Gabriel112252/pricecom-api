class AddTiktokFinancialSyncTracking < ActiveRecord::Migration[7.2]
  def change
    add_column :orders, :financial_sync_attempts, :integer, null: false, default: 0
    add_column :orders, :financial_last_attempt_at, :datetime
    add_column :orders, :financial_next_attempt_at, :datetime
    add_column :orders, :financial_pending_reason, :string

    add_reference :integration_sync_logs, :channel_credential, foreign_key: true
    add_column :integration_sync_logs, :statement_id, :string
    add_column :integration_sync_logs, :statement_time, :datetime
    add_column :integration_sync_logs, :payment_status, :string
    add_column :integration_sync_logs, :transaction_count, :integer, null: false, default: 0
    add_column :integration_sync_logs, :matched_order_count, :integer, null: false, default: 0
    add_column :integration_sync_logs, :synced_order_count, :integer, null: false, default: 0
    add_column :integration_sync_logs, :missing_order_count, :integer, null: false, default: 0
    add_column :integration_sync_logs, :error_count, :integer, null: false, default: 0
    add_column :integration_sync_logs, :payload_checksum, :string
    add_column :integration_sync_logs, :processed_at, :datetime

    add_index :orders, [ :channel_id, :financial_next_attempt_at ],
      name: "index_orders_on_channel_and_financial_next_attempt_at"
    add_index :integration_sync_logs,
      [ :tenant_id, :channel_credential_id, :statement_id ],
      unique: true,
      name: "idx_sync_logs_on_tenant_credential_statement"
  end
end
