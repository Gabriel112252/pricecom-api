class CreateAuditConflicts < ActiveRecord::Migration[7.2]
  def change
    create_table :audit_conflicts do |t|
      t.references :tenant,  null: false, foreign_key: true
      t.references :order,   null: true,  foreign_key: true
      t.references :product, null: true,  foreign_key: true

      t.string  :conflict_type, null: false
      t.string  :severity,      null: false, default: "medium"
      t.string  :status,        null: false, default: "open"
      t.decimal :expected_value, precision: 10, scale: 2, default: "0.0", null: false
      t.decimal :actual_value,   precision: 10, scale: 2, default: "0.0", null: false
      t.decimal :difference,     precision: 10, scale: 2, default: "0.0", null: false
      t.string  :source,        null: false, default: "auto"
      t.text    :notes
      t.datetime :resolved_at
      t.jsonb   :metadata, default: {}, null: false

      t.timestamps
    end

    add_index :audit_conflicts, [:tenant_id, :status],
              name: "index_audit_conflicts_on_tenant_id_and_status"
    add_index :audit_conflicts, [:tenant_id, :conflict_type],
              name: "index_audit_conflicts_on_tenant_id_and_conflict_type"
    add_index :audit_conflicts, [:tenant_id, :severity],
              name: "index_audit_conflicts_on_tenant_id_and_severity"
    add_index :audit_conflicts, :created_at,
              name: "index_audit_conflicts_on_created_at"
  end
end
