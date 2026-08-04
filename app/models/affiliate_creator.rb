class AffiliateCreator < ApplicationRecord
  belongs_to :tenant
  belongs_to :channel

  has_many :affiliate_messages, dependent: :destroy
  has_many :affiliate_campaign_recipients, dependent: :destroy
  has_many :affiliate_campaigns, through: :affiliate_campaign_recipients

  validates :creator_open_id, presence: true, uniqueness: { scope: [ :tenant_id, :channel_id ] }
end
