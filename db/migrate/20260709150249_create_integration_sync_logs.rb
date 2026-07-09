class CreateIntegrationSyncLogs < ActiveRecord::Migration[7.2]
  def change
    create_table :integration_sync_logs do |t|
      t.references :tenant,      null: false, foreign_key: true
      t.references :integration, null: true,  foreign_key: true

      t.string  :direction,         null: false  # inbound | outbound
      t.string  :action,            null: false  # ex: import_orders, push_price, fetch_products
      t.string  :status,            null: false  # pending | success | error | skipped

      t.string  :external_id
      t.string  :external_type

      t.jsonb   :request_payload,   null: false, default: {}
      t.jsonb   :response_payload,  null: false, default: {}
      t.text    :error_message

      t.datetime :started_at
      t.datetime :finished_at
      t.integer  :duration_ms

      t.jsonb   :metadata,          null: false, default: {}

      t.timestamps
    end

    add_index :integration_sync_logs, [:tenant_id, :status]
    add_index :integration_sync_logs, [:tenant_id, :direction]
    add_index :integration_sync_logs, [:tenant_id, :created_at]
    add_index :integration_sync_logs, [:integration_id, :status]
    add_index :integration_sync_logs, :metadata, using: :gin
  end
end
