class CreateFinancialSettlements < ActiveRecord::Migration[7.2]
  def change
    create_table :financial_settlements do |t|
      t.references :tenant,           null: false, foreign_key: true
      t.references :financial_source, null: false, foreign_key: true
      t.references :integration,      null: true,  foreign_key: true
      t.references :channel,          null: true,  foreign_key: true

      t.string :external_id
      t.date   :period_start
      t.date   :period_end

      t.decimal :gross_amount,      precision: 12, scale: 2, default: "0.0"
      t.decimal :fee_amount,        precision: 12, scale: 2, default: "0.0"
      t.decimal :discount_amount,   precision: 12, scale: 2, default: "0.0"
      t.decimal :refund_amount,     precision: 12, scale: 2, default: "0.0"
      t.decimal :chargeback_amount, precision: 12, scale: 2, default: "0.0"
      t.decimal :net_amount,        precision: 12, scale: 2, default: "0.0"

      t.date   :expected_payout_date
      t.date   :actual_payout_date
      t.string :status, default: "pending"
      t.jsonb  :metadata, default: {}

      t.timestamps
    end

    add_index :financial_settlements, [:tenant_id, :status],
              name: "index_financial_settlements_on_tenant_id_and_status"
    add_index :financial_settlements, [:tenant_id, :period_start],
              name: "index_financial_settlements_on_tenant_id_and_period_start"
    add_index :financial_settlements, [:tenant_id, :expected_payout_date],
              name: "idx_financial_settlements_on_tenant_id_and_expected_payout_date"
    add_index :financial_settlements, [:financial_source_id, :status],
              name: "index_financial_settlements_on_financial_source_id_and_status"
    add_index :financial_settlements, :external_id
    add_index :financial_settlements, :metadata, using: :gin
  end
end
