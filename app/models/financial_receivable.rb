class FinancialReceivable < ApplicationRecord
  belongs_to :tenant
  belongs_to :financial_source
  belongs_to :financial_settlement_item, optional: true
  belongs_to :order, optional: true

  MONEY_FIELDS = %i[amount fee_amount anticipation_fee_amount net_amount].freeze

  validates :payable_id, presence: true,
                         uniqueness: { scope: %i[tenant_id financial_source_id] }
  validates :status, presence: true
  validates(*MONEY_FIELDS, numericality: { greater_than_or_equal_to: 0 })

  scope :by_payment_date, ->(from, to) { where(payment_date: from..to) }

  def calculated_net_amount
    amount.to_f - fee_amount.to_f - anticipation_fee_amount.to_f
  end
end
