class FinancialSettlementItem < ApplicationRecord
  belongs_to :tenant
  belongs_to :financial_settlement
  belongs_to :order, optional: true
  has_many :financial_receivables, dependent: :nullify

  STATUSES = %w[unmatched matched disputed ignored].freeze

  TRANSACTION_TYPES = %w[sale refund fee chargeback adjustment payout].freeze

  NON_NEGATIVE_FIELDS = %i[
    fee_amount discount_amount refund_amount
    chargeback_amount expected_amount
  ].freeze

  # gross_amount/net_amount podem ser negativos quando transaction_type é
  # "refund" — dinheiro saindo, não entrando. Payables de estorno reais
  # (originator_model: "refund", amount negativo) eram rejeitados
  # silenciosamente pela validação >= 0 antes desse fix, descartando todo
  # estorno da Pagar.me indefinidamente.
  SIGNED_FOR_REFUND_FIELDS = %i[gross_amount net_amount].freeze

  validates :status, inclusion: { in: STATUSES }
  validates :transaction_type, inclusion: { in: TRANSACTION_TYPES }
  validates(*NON_NEGATIVE_FIELDS, numericality: { greater_than_or_equal_to: 0 })
  validates(*SIGNED_FOR_REFUND_FIELDS, numericality: { greater_than_or_equal_to: 0 }, unless: :refund?)
  validates(*SIGNED_FOR_REFUND_FIELDS, numericality: true, if: :refund?)
  validates :difference_amount, numericality: true
  # nil = sem PaymentFeeRule cadastrada pra essa combinação (não "bateu
  # certinho") — diferente de expected_amount/difference_amount acima, que
  # são sempre preenchidos pela reconciliação pedido x repasse.
  validates :expected_fee_amount, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :fee_difference_amount, numericality: true, allow_nil: true

  def calculated_net_amount
    gross_amount.to_f - fee_amount.to_f - discount_amount.to_f - refund_amount.to_f - chargeback_amount.to_f
  end

  def matched?
    order_id.present? && status == "matched"
  end

  def refund?
    transaction_type == "refund"
  end
end
