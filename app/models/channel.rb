class Channel < ApplicationRecord
  belongs_to :tenant
  has_many :orders, dependent: :nullify
  has_many :carts,  dependent: :destroy
  has_many :freight_quotes, dependent: :destroy
  has_many :freight_margin_dailies, dependent: :destroy
  has_many :pricing_rules, dependent: :destroy
  has_many :channel_operational_costs, dependent: :destroy
  has_many :integrations, dependent: :nullify
  has_many :financial_sources, dependent: :nullify
  has_many :financial_settlements, dependent: :nullify

  PLATFORMS = %w[tiktok shopify yampi mercadolivre shopee].freeze

  # Readable default names for a Channel auto-created from a connected
  # ChannelCredential/provider string — falls back to a plain capitalize
  # for anything not listed (there shouldn't be, since PLATFORMS is closed).
  DEFAULT_NAMES = {
    "yampi"        => "Yampi",
    "shopify"      => "Shopify",
    "tiktok"       => "TikTok Shop",
    "mercadolivre" => "Mercado Livre",
    "shopee"       => "Shopee"
  }.freeze

  validates :platform, inclusion: { in: PLATFORMS }
  validates :name, presence: true

  # Every ChannelCredential connection (and, historically, some order
  # imports — see Orders::ImportService) needs a matching Channel row for
  # Order#channel_id/#channel to resolve against. Centralized here so the
  # one true "make sure this tenant+platform has a Channel" operation has a
  # single, reusable implementation instead of being duplicated wherever a
  # channel gets connected or backfilled.
  def self.ensure_for!(tenant, platform)
    tenant.channels.find_or_create_by!(platform: platform) do |c|
      c.name = DEFAULT_NAMES.fetch(platform, platform.to_s.capitalize)
    end
  end
end
