class Integration < ApplicationRecord
  belongs_to :tenant
  belongs_to :channel, optional: true

  PROVIDERS = %w[idworks yampi shopify tiktok mercadolivre generic].freeze
  STATUSES  = %w[disconnected connected error syncing].freeze

  validates :provider, presence: true, inclusion: { in: PROVIDERS }
  validates :name,     presence: true
  validates :status,   inclusion: { in: STATUSES }
  validates :name, uniqueness: { scope: [:tenant_id, :provider] }

  has_many :integration_mappings,  dependent: :destroy
  has_many :integration_sync_logs, dependent: :nullify
  has_many :integration_events,    dependent: :nullify
  has_many :order_refunds,         dependent: :nullify

  scope :active,      -> { where(active: true) }
  scope :by_provider, ->(p) { where(provider: p) }

  def credentials_configured?
    credentials.present? && credentials.any?
  end
end
