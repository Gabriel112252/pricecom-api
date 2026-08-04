class AffiliateCampaignRecipient < ApplicationRecord
  STATUSES = %w[pending sent failed].freeze

  belongs_to :affiliate_campaign
  belongs_to :affiliate_creator
  belongs_to :affiliate_message, optional: true

  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :affiliate_creator_id, uniqueness: { scope: :affiliate_campaign_id }
end
