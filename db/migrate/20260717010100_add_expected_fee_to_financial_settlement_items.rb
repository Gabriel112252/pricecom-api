class AddExpectedFeeToFinancialSettlementItems < ActiveRecord::Migration[7.2]
  def change
    # Dedicated to the negotiated-rate fee check (PaymentFeeRule), distinct
    # from expected_amount/difference_amount — those are already used by
    # Financials::MatchSettlementItem for order-vs-settlement reconciliation
    # (a different comparison). Nullable on purpose: nil means "no rule
    # cadastrada para essa combinação", never conflated with "bateu certinho".
    add_column :financial_settlement_items, :expected_fee_amount, :decimal, precision: 12, scale: 2
    add_column :financial_settlement_items, :fee_difference_amount, :decimal, precision: 12, scale: 2
  end
end
