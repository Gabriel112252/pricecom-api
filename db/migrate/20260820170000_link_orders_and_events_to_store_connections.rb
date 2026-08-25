class LinkOrdersAndEventsToStoreConnections < ActiveRecord::Migration[7.2]
  def up
    add_reference :orders,
      :channel_credential,
      null: true,
      foreign_key: { on_delete: :nullify }

    # At deploy time this runs immediately after the migration that enables
    # multiple credentials. Existing data still has the historical 1:1
    # tenant+provider shape, so the backfill is deterministic.
    execute <<~SQL
      UPDATE orders AS orders
      SET channel_credential_id = credentials.id
      FROM channels AS channels,
           channel_credentials AS credentials
      WHERE channels.id = orders.channel_id
        AND channels.tenant_id = orders.tenant_id
        AND credentials.tenant_id = orders.tenant_id
        AND credentials.channel = channels.platform
        AND orders.channel_credential_id IS NULL
    SQL

    add_index :orders,
      [ :tenant_id, :channel_credential_id, :external_id ],
      name: "idx_orders_tenant_credential_external"

    add_reference :integration_events,
      :channel_credential,
      null: true,
      foreign_key: { on_delete: :nullify }

    execute <<~SQL
      UPDATE integration_events AS events
      SET channel_credential_id = credentials.id
      FROM channel_credentials AS credentials
      WHERE credentials.tenant_id = events.tenant_id
        AND credentials.channel = events.provider
        AND events.channel_credential_id IS NULL
    SQL

    add_index :integration_events,
      [ :tenant_id, :channel_credential_id, :external_type, :external_id ],
      name: "idx_integration_events_store_external"
  end

  def down
    remove_index :integration_events, name: "idx_integration_events_store_external"
    remove_reference :integration_events, :channel_credential, foreign_key: true

    remove_index :orders, name: "idx_orders_tenant_credential_external"
    remove_reference :orders, :channel_credential, foreign_key: true
  end
end
