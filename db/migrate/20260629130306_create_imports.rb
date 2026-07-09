class CreateImports < ActiveRecord::Migration[7.2]
  def change
    create_table :imports do |t|
      t.references :tenant, null: false, foreign_key: true
      t.references :channel, null: true, foreign_key: true
      t.string :filename
      t.string :status, default: "pending"
      t.integer :total_rows, default: 0
      t.integer :processed_rows, default: 0
      t.integer :error_rows, default: 0
      t.jsonb :errors_log, default: []
      t.datetime :finished_at
      t.timestamps
    end
  end
end
