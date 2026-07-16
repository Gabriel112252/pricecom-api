class CreateFreightQuotes < ActiveRecord::Migration[7.2]
  def change
    create_table :freight_quotes do |t|
      t.references :tenant,  null: false, foreign_key: true
      t.references :channel, null: false, foreign_key: true

      t.string :external_id, null: false # o "id" (uuid) do log LucroFrete
      t.string :cart_external_id         # request_payload.cart.id — bate com Cart#external_id
      t.string :origin_cep
      t.string :destination_cep
      t.string :destination_state
      t.integer :total_weight_grams
      t.datetime :quoted_at
      # Array normalizado de opções cotadas: slot_name, carrier_name,
      # service, name, price, cost_price, free_shipment, source_provider, days.
      t.jsonb :quotes, default: [], null: false

      t.timestamps
    end

    add_index :freight_quotes, [ :tenant_id, :external_id ], unique: true
    add_index :freight_quotes, [ :tenant_id, :cart_external_id ]
    add_index :freight_quotes, [ :tenant_id, :quoted_at ]
  end
end
