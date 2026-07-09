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

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true
end
