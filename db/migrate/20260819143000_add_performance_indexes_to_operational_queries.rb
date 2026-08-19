class AddPerformanceIndexesToOperationalQueries < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  def change
    add_index :orders,
      [ :tenant_id, :channel_id, :ordered_at ],
      name: "idx_orders_tenant_channel_ordered_at",
      algorithm: :concurrently,
      if_not_exists: true

    add_index :orders,
      [ :tenant_id, :order_type, :ordered_at ],
      name: "idx_orders_tenant_type_ordered_at",
      algorithm: :concurrently,
      if_not_exists: true

    add_index :orders,
      [ :tenant_id, :order_number ],
      name: "idx_orders_tenant_order_number",
      algorithm: :concurrently,
      if_not_exists: true

    add_index :carts,
      [ :tenant_id, :status, :abandoned_at ],
      name: "idx_carts_tenant_status_abandoned_at",
      algorithm: :concurrently,
      if_not_exists: true

    add_index :audit_conflicts,
      [ :tenant_id, :status, :conflict_type, :created_at ],
      name: "idx_audit_conflicts_tenant_status_type_created",
      algorithm: :concurrently,
      if_not_exists: true

    add_index :idworks_orders,
      [ :tenant_id, :order_number ],
      name: "idx_idworks_orders_tenant_order_number",
      algorithm: :concurrently,
      if_not_exists: true

    add_index :idworks_orders,
      [ :tenant_id, :external_id ],
      name: "idx_idworks_orders_tenant_external_id",
      algorithm: :concurrently,
      if_not_exists: true

    add_index :integration_sync_logs,
      [ :tenant_id, :external_id, :created_at ],
      name: "idx_sync_logs_tenant_external_created",
      algorithm: :concurrently,
      if_not_exists: true
  end
end
