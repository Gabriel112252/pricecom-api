class CreateIntegrationEvents < ActiveRecord::Migration[7.2]
  def change
    create_table :integration_events do |t|
      t.references :tenant,      null: false, foreign_key: true
      t.references :integration, null: true,  foreign_key: true

      t.string   :provider,       null: false
      t.string   :event_type,     null: false
      t.string   :external_id
      t.string   :external_type
      t.string   :status,         null: false, default: "pending"

      t.jsonb    :payload,        null: false, default: {}
      t.jsonb    :headers,        null: false, default: {}
      t.jsonb    :metadata,       null: false, default: {}

      t.datetime :received_at
      t.datetime :processed_at
      t.text     :error_message

      t.timestamps
    end

    add_index :integration_events, [:tenant_id, :status]
    add_index :integration_events, [:tenant_id, :provider]
    add_index :integration_events, [:tenant_id, :event_type]
    add_index :integration_events, [:integration_id, :external_id, :event_type],
              name: "idx_integration_events_on_integration_external"
    add_index :integration_events, :received_at
    add_index :integration_events, :payload, using: :gin
  end
end
