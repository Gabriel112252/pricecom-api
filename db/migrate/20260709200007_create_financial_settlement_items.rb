class CreateFinancialSettlementItems < ActiveRecord::Migration[7.2]
  def change
    create_table :financial_settlement_items do |t|
      t.references :tenant,               null: false, foreign_key: true
      t.references :financial_settlement, null: false, foreign_key: true
      t.references :order,                null: true,  foreign_key: true

      t.string :external_id
      t.string :external_order_id
      t.string :transaction_type, default: "sale"

      t.decimal :gross_amount,      precision: 12, scale: 2, default: "0.0"
      t.decimal :fee_amount,        precision: 12, scale: 2, default: "0.0"
      t.decimal :discount_amount,   precision: 12, scale: 2, default: "0.0"
      t.decimal :refund_amount,     precision: 12, scale: 2, default: "0.0"
      t.decimal :chargeback_amount, precision: 12, scale: 2, default: "0.0"
      t.decimal :net_amount,        precision: 12, scale: 2, default: "0.0"
      t.decimal :expected_amount,   precision: 12, scale: 2, default: "0.0"
      t.decimal :difference_amount, precision: 12, scale: 2, default: "0.0"

      t.string   :status, default: "unmatched"
      t.datetime :transaction_date
      t.date     :payout_date
      t.jsonb    :metadata, default: {}

      t.timestamps
    end

    add_index :financial_settlement_items, [:tenant_id, :status],
              name: "index_financial_settlement_items_on_tenant_id_and_status"
    add_index :financial_settlement_items, [:financial_settlement_id, :status],
              name: "idx_financial_settlement_items_on_settlement_id_and_status"
    add_index :financial_settlement_items, :external_order_id
    add_index :financial_settlement_items, :transaction_date
    add_index :financial_settlement_items, :metadata, using: :gin
  end
end
