class Tenant < ApplicationRecord
  has_many :users, dependent: :destroy
  has_many :channels, dependent: :destroy
  has_many :products, dependent: :destroy
  has_many :orders,        dependent: :destroy
  has_many :order_refunds, dependent: :destroy
  has_many :imports, dependent: :destroy
  has_many :integrations,          dependent: :destroy
  has_many :integration_mappings,  dependent: :destroy
  has_many :integration_sync_logs, dependent: :destroy
  has_many :integration_events,    dependent: :destroy
  has_many :audit_conflicts, dependent: :destroy
  has_many :financial_sources, dependent: :destroy
  has_many :financial_settlements, dependent: :destroy
  has_many :financial_settlement_items, dependent: :destroy
  has_many :financial_receivables, dependent: :destroy
  has_many :channel_credentials, dependent: :destroy
  has_many :channel_product_listings, dependent: :destroy
  has_many :data_source_configs, dependent: :destroy

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true

  # Long, unguessable — this token is the ONLY thing standing between the
  # public /tv/:token route and this tenant's dashboard data, so it must
  # not be practically brute-forceable.
  def regenerate_tv_token!
    update!(tv_token: SecureRandom.urlsafe_base64(32))
  end

  def revoke_tv_token!
    update!(tv_token: nil)
  end
end
