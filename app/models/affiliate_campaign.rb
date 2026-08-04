class AffiliateCampaign < ApplicationRecord
  STATUSES = %w[draft sending completed].freeze

  belongs_to :tenant
  belongs_to :channel
  belongs_to :created_by, class_name: "User", optional: true

  has_many :affiliate_campaign_recipients, dependent: :destroy
  has_many :affiliate_creators, through: :affiliate_campaign_recipients

  validates :name, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
end
