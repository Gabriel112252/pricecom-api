class CreateTestimonialBulkImports < ActiveRecord::Migration[7.2]
  def change
    create_table :testimonial_bulk_imports do |t|
      t.references :tenant, null: false, foreign_key: true

      t.string :filename
      t.string :status, default: "pending", null: false # pending | processing | done | failed
      t.integer :total_rows, default: 0, null: false
      t.integer :processed_rows, default: 0, null: false
      t.integer :error_rows, default: 0, null: false
      t.jsonb :errors_log, default: [], null: false
      t.datetime :finished_at

      t.timestamps
    end
  end
end
