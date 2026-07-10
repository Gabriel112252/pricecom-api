class AddResolvedByToAuditConflicts < ActiveRecord::Migration[7.2]
  def change
    add_reference :audit_conflicts, :resolved_by, null: true, foreign_key: { to_table: :users }
  end
end
