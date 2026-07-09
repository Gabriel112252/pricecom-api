class FinancialSource < ApplicationRecord
  belongs_to :tenant
  belongs_to :integration, optional: true
  belongs_to :channel,     optional: true

  has_many :financial_settlements, dependent: :destroy

  PROVIDERS = %w[
    shopify_payments
    yampi
    pagarme
    tiktok
    mercado_pago
    banco
    manual
    generic
  ].freeze

  SOURCE_TYPES = %w[gateway marketplace bank manual erp generic].freeze
  STATUSES     = %w[active inactive error syncing].freeze

  validates :provider, presence: true, inclusion: { in: PROVIDERS }
  validates :name,     presence: true
  validates :source_type, inclusion: { in: SOURCE_TYPES }
  validates :status,      inclusion: { in: STATUSES }

  scope :active,          -> { where(active: true) }
  scope :by_provider,     ->(provider) { where(provider: provider) }
  scope :by_source_type,  ->(source_type) { where(source_type: source_type) }
  scope :gateways,        -> { where(source_type: "gateway") }
  scope :marketplaces,    -> { where(source_type: "marketplace") }
  scope :banks,           -> { where(source_type: "bank") }

  def credentials_configured?
    credentials.present? && credentials.any?
  end
end
