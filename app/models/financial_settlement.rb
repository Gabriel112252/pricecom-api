class FinancialSettlement < ApplicationRecord
  belongs_to :tenant
  belongs_to :financial_source
  belongs_to :integration, optional: true
  belongs_to :channel,     optional: true

  has_many :financial_settlement_items, dependent: :destroy

  STATUSES = %w[pending partial paid overdue disputed canceled].freeze

  MONEY_FIELDS = %i[gross_amount fee_amount discount_amount refund_amount chargeback_amount net_amount].freeze

  validates :status, inclusion: { in: STATUSES }
  validates(*MONEY_FIELDS, numericality: { greater_than_or_equal_to: 0 })

  scope :pending,  -> { where(status: "pending") }
  scope :paid,     -> { where(status: "paid") }
  scope :overdue,  -> { where(status: "overdue") }
  scope :disputed, -> { where(status: "disputed") }
  scope :by_period, ->(from, to) { where(period_start: from..to) }
  scope :recent,   -> { order(created_at: :desc) }

  def calculated_net_amount
    gross_amount.to_f - fee_amount.to_f - discount_amount.to_f - refund_amount.to_f - chargeback_amount.to_f
  end

  def payout_delay_days
    return nil unless actual_payout_date && expected_payout_date

    (actual_payout_date - expected_payout_date).to_i
  end
end
