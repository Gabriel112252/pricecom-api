class FinancialSettlementItem < ApplicationRecord
  belongs_to :tenant
  belongs_to :financial_settlement
  belongs_to :order, optional: true

  STATUSES = %w[unmatched matched disputed ignored].freeze

  TRANSACTION_TYPES = %w[sale refund fee chargeback adjustment payout].freeze

  NON_NEGATIVE_FIELDS = %i[
    gross_amount fee_amount discount_amount refund_amount
    chargeback_amount net_amount expected_amount
  ].freeze

  validates :status, inclusion: { in: STATUSES }
  validates :transaction_type, inclusion: { in: TRANSACTION_TYPES }
  validates(*NON_NEGATIVE_FIELDS, numericality: { greater_than_or_equal_to: 0 })
  validates :difference_amount, numericality: true

  def calculated_net_amount
    gross_amount.to_f - fee_amount.to_f - discount_amount.to_f - refund_amount.to_f - chargeback_amount.to_f
  end

  def matched?
    order_id.present? && status == "matched"
  end
end
