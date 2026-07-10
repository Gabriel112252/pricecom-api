class Channel < ApplicationRecord
  belongs_to :tenant
  has_many :orders, dependent: :nullify
  has_many :pricing_rules, dependent: :destroy
  has_many :channel_operational_costs, dependent: :destroy
  has_many :integrations, dependent: :nullify
  has_many :financial_sources, dependent: :nullify
  has_many :financial_settlements, dependent: :nullify

  PLATFORMS = %w[tiktok shopify yampi mercadolivre shopee].freeze
  validates :platform, inclusion: { in: PLATFORMS }
  validates :name, presence: true
end
