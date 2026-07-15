class CreateFinancialReceivables < ActiveRecord::Migration[7.2]
  def change
    create_table :financial_receivables do |t|
      t.references :tenant, null: false, foreign_key: true
      t.references :financial_source, null: false, foreign_key: true
      t.references :financial_settlement_item, foreign_key: true
      t.references :order, foreign_key: true

      t.string :payable_id, null: false
      t.string :status, null: false
      t.decimal :amount, precision: 12, scale: 2, default: "0.0", null: false
      t.decimal :fee_amount, precision: 12, scale: 2, default: "0.0", null: false
      t.decimal :anticipation_fee_amount, precision: 12, scale: 2, default: "0.0", null: false
      t.decimal :net_amount, precision: 12, scale: 2, default: "0.0", null: false
      t.integer :installment
      t.string :transaction_id
      t.string :charge_id
      t.string :recipient_id
      t.string :payment_method
      t.date :payment_date
      t.date :original_payment_date
      t.datetime :accrual_date
      t.datetime :date_created
      t.jsonb :raw_payload, default: {}, null: false

      t.timestamps
    end

    add_index :financial_receivables, [ :tenant_id, :financial_source_id, :payable_id ],
              unique: true,
              name: "idx_financial_receivables_on_source_payable"
    add_index :financial_receivables, [ :tenant_id, :payment_date, :status ],
              name: "idx_financial_receivables_on_tenant_payment_status"
    add_index :financial_receivables, [ :financial_source_id, :payment_date ],
              name: "idx_financial_receivables_on_source_payment_date"
    add_index :financial_receivables, :charge_id
    add_index :financial_receivables, :transaction_id
    add_index :financial_receivables, :payment_method
  end
end
