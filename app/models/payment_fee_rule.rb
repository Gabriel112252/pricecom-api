class PaymentFeeRule < ApplicationRecord
  belongs_to :tenant

  PAYMENT_METHODS = %w[credit_card pix boleto].freeze
  CARD_BRANDS = %w[visa mastercard elo hipercard amex].freeze
  RATE_TYPES = %w[percentage fixed_amount].freeze

  validates :payment_method, presence: true, inclusion: { in: PAYMENT_METHODS }
  validates :card_brand, inclusion: { in: CARD_BRANDS }, allow_nil: true
  validates :rate_type, presence: true, inclusion: { in: RATE_TYPES }
  validates :rate_value, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :installments_from, :installments_to, presence: true,
    numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :fixed_fee_boleto, :fixed_fee_gateway, :fixed_fee_antifraud, :withdrawal_fee,
    numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :anticipation_rate, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :valid_from, presence: true
  validate :installments_range_ordered
  validate :card_brand_matches_payment_method

  scope :for_method, ->(method) { where(payment_method: method) }

  # Regra vigente para uma cobrança: mesmo payment_method, mesma bandeira
  # (ou sem bandeira quando não aplicável, ex: pix/boleto), parcela dentro
  # da faixa, e data da transação dentro da validade. Sem sobreposição
  # garantida no cadastro — se mais de uma regra bater, a mais recente
  # (valid_from) vence, como critério de desempate explícito.
  def self.find_for(tenant:, payment_method:, card_brand:, installment:, date:)
    return nil if payment_method.blank?

    installment = installment.presence || 1
    date ||= Date.current

    scope = tenant.payment_fee_rules
      .where(payment_method: payment_method)
      .where("installments_from <= :i AND installments_to >= :i", i: installment)
      .where("valid_from <= :d", d: date)
      .where("valid_until IS NULL OR valid_until >= :d", d: date)

    scope = card_brand.present? ? scope.where(card_brand: card_brand) : scope.where(card_brand: nil)

    scope.order(valid_from: :desc).first
  end

  private

  def installments_range_ordered
    return if installments_from.blank? || installments_to.blank?

    errors.add(:installments_to, "deve ser maior ou igual a installments_from") if installments_to < installments_from
  end

  def card_brand_matches_payment_method
    if payment_method == "credit_card" && card_brand.blank?
      errors.add(:card_brand, "é obrigatório para cartão de crédito")
    elsif payment_method != "credit_card" && card_brand.present?
      errors.add(:card_brand, "não se aplica a #{payment_method}")
    end
  end
end
