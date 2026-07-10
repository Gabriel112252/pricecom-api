class AddRoleToUsers < ActiveRecord::Migration[7.2]
  # `users.role` already existed (default "member", nullable, no enum
  # backing it) — this migration switches it over to the real
  # admin/operador system instead of adding a duplicate column.
  def up
    change_column_default :users, :role, from: "member", to: "operador"

    # Nobody gets locked out by this migration: any row still carrying the
    # old "member" default (or somehow null) keeps full access.
    User.where(role: [nil, "member"]).update_all(role: "admin")

    change_column_null :users, :role, false
  end

  def down
    change_column_null :users, :role, true
    change_column_default :users, :role, from: "operador", to: "member"
  end
end
