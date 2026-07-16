class CreateFreightMarginDailies < ActiveRecord::Migration[7.2]
  def change
    create_table :freight_margin_dailies do |t|
      t.references :tenant,  null: false, foreign_key: true
      t.references :channel, null: false, foreign_key: true
      t.date :date, null: false

      t.integer :order_count, default: 0, null: false
      t.decimal :freight_charged, precision: 12, scale: 2, default: "0.0", null: false
      t.decimal :freight_cost,    precision: 12, scale: 2, default: "0.0", null: false
      t.decimal :margin_value,    precision: 12, scale: 2, default: "0.0", null: false
      # Margem % observada hoje fica entre -90% e -245% — precision folgada.
      t.decimal :margin_percent,  precision: 8,  scale: 2
      # O endpoint /reports/timeline NÃO traz free_shipping por dia (só o
      # /reports/summary agregado traz) — fica NULL por dia de propósito;
      # não inventamos rateio diário de um número agregado.
      t.integer :free_shipping_count
      t.datetime :synced_at

      t.timestamps
    end

    add_index :freight_margin_dailies, [ :tenant_id, :channel_id, :date ], unique: true
    add_index :freight_margin_dailies, [ :tenant_id, :date ]
  end
end
