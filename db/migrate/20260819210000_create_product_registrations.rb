class CreateProductRegistrations < ActiveRecord::Migration[7.2]
  def change
    create_table :product_registrations do |t|
      t.references :tenant, null: false, foreign_key: true
      t.references :parent_product, null: false, foreign_key: { to_table: :products }
      t.references :product, null: true, foreign_key: true
      t.references :created_by_user,
        null: true,
        foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :sku, null: false
      t.string :name, null: false
      t.integer :price_cents
      t.string :status, null: false, default: "draft"
      t.jsonb :metadata, null: false, default: {}
      t.jsonb :validation_errors, null: false, default: []
      t.timestamps
    end

    add_index :product_registrations, [ :tenant_id, :status ]
    add_index :product_registrations, [ :tenant_id, :sku ]

    create_table :product_registration_publications do |t|
      t.references :product_registration, null: false, foreign_key: true
      t.string :channel, null: false
      t.string :status, null: false, default: "planned"
      t.string :external_product_id
      t.string :external_variant_id
      t.string :error_code
      t.text :error_message
      t.integer :attempts, null: false, default: 0
      t.datetime :last_attempt_at
      t.datetime :published_at
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :product_registration_publications,
      [ :product_registration_id, :channel ],
      unique: true,
      name: "idx_product_registration_publications_channel"
  end
end
