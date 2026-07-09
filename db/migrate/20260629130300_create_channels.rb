class CreateChannels < ActiveRecord::Migration[7.2]
  def change
    create_table :channels do |t|
      t.references :tenant, null: false, foreign_key: true
      t.string :name, null: false
      t.string :platform, null: false
      t.decimal :commission_pct, precision: 5, scale: 2, default: 0
      t.decimal :commission_fixed, precision: 10, scale: 2, default: 0
      t.string :commission_source, default: "manual"
      t.jsonb :credentials, default: {}
      t.boolean :active, default: true
      t.timestamps
    end
    add_index :channels, [:tenant_id, :platform]
  end
end
