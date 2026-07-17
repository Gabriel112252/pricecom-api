class CreatePaymentFeeRules < ActiveRecord::Migration[7.2]
  def change
    create_table :payment_fee_rules do |t|
      t.references :tenant, null: false, foreign_key: true

      t.string :payment_method, null: false
      t.string :card_brand
      t.integer :installments_from, null: false, default: 1
      t.integer :installments_to, null: false, default: 1
      t.string :rate_type, null: false
      t.decimal :rate_value, precision: 8, scale: 4, null: false
      t.decimal :fixed_fee_boleto, precision: 10, scale: 2, default: "0.0"
      t.decimal :fixed_fee_gateway, precision: 10, scale: 2, default: "0.0"
      t.decimal :fixed_fee_antifraud, precision: 10, scale: 2, default: "0.0"
      t.decimal :withdrawal_fee, precision: 10, scale: 2, default: "0.0"
      t.decimal :anticipation_rate, precision: 8, scale: 4, default: "0.0"
      t.date :valid_from, null: false
      t.date :valid_until

      t.timestamps
    end

    add_index :payment_fee_rules, [ :tenant_id, :payment_method, :card_brand ],
              name: "idx_payment_fee_rules_on_tenant_method_brand"
    add_index :payment_fee_rules, [ :tenant_id, :valid_from ]
  end
end
