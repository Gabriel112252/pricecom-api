class CreateChannelCredentials < ActiveRecord::Migration[7.2]
  def change
    create_table :channel_credentials do |t|
      t.references :tenant, null: false, foreign_key: true
      t.string :channel, null: false
      # jsonb column; the Ruby-level `encrypts` declaration on the model
      # (Rails 7 Active Record Encryption) encrypts the serialized value
      # before it ever reaches this column — never store plaintext here.
      t.jsonb :credentials, null: false, default: {}
      t.string :status, null: false, default: "pending"
      t.datetime :last_synced_at

      t.timestamps
    end

    add_index :channel_credentials, [:tenant_id, :channel], unique: true
  end
end
