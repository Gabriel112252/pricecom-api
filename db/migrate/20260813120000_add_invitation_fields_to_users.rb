class AddInvitationFieldsToUsers < ActiveRecord::Migration[7.2]
  def change
    add_column :users, :invitation_token, :string
    add_column :users, :invitation_sent_at, :datetime
    add_column :users, :invitation_accepted_at, :datetime
    add_index :users, :invitation_token, unique: true

    # Convidado nasce sem senha (definida só em #accept_invitation, via
    # has_secure_password) — password_digest não pode mais ser NOT NULL.
    # Usuários existentes já têm o valor preenchido, então relaxar a
    # constraint não afeta nenhuma linha atual.
    change_column_null :users, :password_digest, true
  end
end
