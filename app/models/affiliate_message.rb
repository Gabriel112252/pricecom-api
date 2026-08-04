class AffiliateMessage < ApplicationRecord
  DIRECTIONS = %w[outbound inbound].freeze

  belongs_to :affiliate_creator
  has_one :affiliate_campaign_recipient, foreign_key: :affiliate_message_id, inverse_of: :affiliate_message

  validates :direction, presence: true, inclusion: { in: DIRECTIONS }
end
