class CreateDataSourceConfigs < ActiveRecord::Migration[7.2]
  def change
    create_table :data_source_configs do |t|
      t.references :tenant, null: false, foreign_key: true
      t.string :data_type, null: false   # cost | freight | tax | payment_reconciliation
      t.string :source, null: false      # idworks | pagarme | (futuros)
      t.boolean :enabled, default: true
      t.timestamps
    end
    add_index :data_source_configs, [ :tenant_id, :data_type ], unique: true
  end
end
