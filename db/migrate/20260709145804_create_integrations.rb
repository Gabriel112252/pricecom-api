class CreateIntegrations < ActiveRecord::Migration[7.2]
  def change
    create_table :integrations do |t|
      t.references :tenant, null: false, foreign_key: true
      t.references :channel, null: true, foreign_key: true

      t.string :provider, null: false
      t.string :name, null: false
      t.string :status, null: false, default: "disconnected"

      t.jsonb :settings, null: false, default: {}
      t.jsonb :credentials, null: false, default: {}

      t.datetime :last_synced_at
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :integrations, [:tenant_id, :provider, :name], unique: true
    add_index :integrations, [:tenant_id, :provider]
    add_index :integrations, [:tenant_id, :status]
    add_index :integrations, :settings, using: :gin
  end
end