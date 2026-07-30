class Tenant < ApplicationRecord
  has_many :users, dependent: :destroy
  has_many :channels, dependent: :destroy
  has_many :products, dependent: :destroy
  has_many :orders,        dependent: :destroy
  has_many :carts,         dependent: :destroy
  has_many :freight_quotes, dependent: :destroy
  has_many :freight_margin_dailies, dependent: :destroy
  has_many :lucrofrete_order_reports, dependent: :destroy
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
  has_many :payment_fee_rules, dependent: :destroy
  has_many :stock_snapshots, dependent: :destroy
  has_many :stock_alert_rules, dependent: :destroy
  has_many :stock_alerts, dependent: :destroy
  has_many :stock_movements, dependent: :destroy
  has_many :stock_replenishment_executions, dependent: :destroy
  has_many :testimonials, dependent: :destroy
  has_many :testimonial_bulk_imports, dependent: :destroy
  has_many :reconciliation_items, dependent: :destroy
  has_many :shop_analytics_snapshots, dependent: :destroy

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

  # Same reasoning as tv_token above — the only thing standing between the
  # public /api/public/v1/testimonials route and this tenant's testimonials.
  # Deliberately NOT slug: slug is a plain readable identifier, not a
  # secret, and would let anyone enumerate other tenants' published
  # testimonials by guessing slugs.
  def regenerate_testimonials_public_token!
    update!(testimonials_public_token: SecureRandom.urlsafe_base64(32))
  end

  def revoke_testimonials_public_token!
    update!(testimonials_public_token: nil)
  end
end
