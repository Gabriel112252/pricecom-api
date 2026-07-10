class ChannelProductListing < ApplicationRecord
  belongs_to :tenant
  belongs_to :product

  validates :channel, presence: true, inclusion: { in: ChannelCredential::CHANNELS }
  validates :external_id, presence: true, uniqueness: { scope: [ :tenant_id, :channel ] }

  scope :for_channel, ->(channel) { where(channel: channel) }
  scope :stale, ->(before) { where("synced_at < ?", before) }
end
