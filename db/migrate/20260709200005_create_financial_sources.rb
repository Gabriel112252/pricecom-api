class CreateFinancialSources < ActiveRecord::Migration[7.2]
  def change
    create_table :financial_sources do |t|
      t.references :tenant,      null: false, foreign_key: true
      t.references :integration, null: true,  foreign_key: true
      t.references :channel,     null: true,  foreign_key: true

      t.string  :provider,    null: false
      t.string  :name,        null: false
      t.string  :source_type, null: false, default: "gateway"
      t.string  :status,      null: false, default: "active"
      t.jsonb   :settings,    null: false, default: {}
      t.jsonb   :credentials, null: false, default: {}
      t.boolean :active,      null: false, default: true
      t.datetime :last_synced_at

      t.timestamps
    end

    add_index :financial_sources, [:tenant_id, :provider, :name],
              unique: true,
              name: "index_financial_sources_on_tenant_id_and_provider_and_name"
    add_index :financial_sources, [:tenant_id, :provider],
              name: "index_financial_sources_on_tenant_id_and_provider"
    add_index :financial_sources, [:tenant_id, :source_type],
              name: "index_financial_sources_on_tenant_id_and_source_type"
    add_index :financial_sources, [:tenant_id, :status],
              name: "index_financial_sources_on_tenant_id_and_status"
    add_index :financial_sources, :settings, using: :gin
  end
end
