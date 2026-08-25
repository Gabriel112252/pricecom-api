class ChannelProductListing < ApplicationRecord
  SELLING_STATUSES = %w[selling draft inactive reviewing rejected platform_blocked deleted unknown].freeze
  STATUS_STALE_AFTER = 6.hours

  belongs_to :tenant
  belongs_to :product
  belongs_to :channel_credential, optional: true
  has_many :stock_replenishment_executions, dependent: :destroy

  validates :channel, presence: true, inclusion: { in: ChannelCredential::CHANNELS }
  validates :external_id, presence: true
  validates :external_id,
    uniqueness: { scope: [ :tenant_id, :channel_credential_id ] },
    if: -> { channel_credential_id.present? }
  validates :external_id,
    uniqueness: { scope: [ :tenant_id, :channel ] },
    unless: -> { channel_credential_id.present? }
  validates :channel_priority, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :selling_status, presence: true, inclusion: { in: SELLING_STATUSES }
  validate :channel_credential_matches_listing

  scope :for_channel, ->(channel) { where(channel: channel) }
  scope :for_connection, ->(credential) { where(channel_credential: credential) }
  scope :stale, ->(before) { where("synced_at < ?", before) }
  scope :replenishment_eligible, -> { where(replenishment_eligible: true) }

  def status_stale?
    remote_status_synced_at.nil? || remote_status_synced_at < STATUS_STALE_AFTER.ago
  end

  def connection_name
    channel_credential&.display_name || channel.to_s.humanize
  end

  private

  def channel_credential_matches_listing
    return unless channel_credential

    if channel_credential.tenant_id != tenant_id
      errors.add(:channel_credential, "deve pertencer à mesma empresa")
    end

    if channel_credential.channel != channel
      errors.add(:channel_credential, "deve ser do mesmo canal do anúncio")
    end
  end
end
