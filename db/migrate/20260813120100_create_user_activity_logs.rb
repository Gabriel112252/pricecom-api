class CreateUserActivityLogs < ActiveRecord::Migration[7.2]
  def change
    create_table :user_activity_logs do |t|
      t.references :tenant, null: false, foreign_key: true

      # nullable — ações do próprio sistema (ex: job em background) não têm
      # um usuário autenticado por trás, mesmo padrão de resolved_by_id em
      # audit_conflicts.
      t.references :user, null: true, foreign_key: true

      t.string :action, null: false

      # Alvo da ação, guardado como tipo+id em vez de belongs_to polimórfico
      # de verdade — não precisamos de query reversa ("todo log de um User
      # específico") além de metadata/filtro simples, e string+id evita uma
      # FK que teria que apontar pra tabelas diferentes por linha.
      t.string :target_type
      t.bigint :target_id

      t.jsonb :metadata, default: {}, null: false

      t.timestamps
    end

    add_index :user_activity_logs, [ :tenant_id, :created_at ]
    add_index :user_activity_logs, [ :tenant_id, :action ]
    add_index :user_activity_logs, [ :target_type, :target_id ]
  end
end
