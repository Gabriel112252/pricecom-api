class CreateIntegrationMappings < ActiveRecord::Migration[7.2]
  def change
    create_table :integration_mappings do |t|
      t.references :tenant,      null: false, foreign_key: true
      t.references :integration, null: false, foreign_key: true

      # Polymorphic — pode estar nil quando dado externo chega antes da entidade local
      t.string  :mappable_type
      t.bigint  :mappable_id

      t.string  :external_id,   null: false
      t.string  :external_code
      t.string  :external_type, null: false
      t.string  :status,        null: false, default: "active"
      t.jsonb   :metadata,      null: false, default: {}
      t.datetime :last_synced_at

      t.timestamps
    end

    # Unicidade de mapeamento: mesma integração não pode mapear o mesmo external_id+type duas vezes
    add_index :integration_mappings, [:integration_id, :external_id, :external_type], unique: true,
              name: "idx_integration_mappings_on_integration_external"

    # Busca por entidade local
    add_index :integration_mappings, [:mappable_type, :mappable_id],
              name: "idx_integration_mappings_on_mappable"

    # Busca por tenant + tipo externo (ex: todos os produtos mapeados de um tenant)
    add_index :integration_mappings, [:tenant_id, :external_type]

    # GIN para queries em metadata
    add_index :integration_mappings, :metadata, using: :gin
  end
end
