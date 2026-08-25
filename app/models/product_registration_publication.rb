class ProductRegistrationPublication < ApplicationRecord
  CHANNELS = %w[shopify yampi tiktok nuvemshop idworks].freeze
  STATUSES = %w[planned publishing published failed waiting_connector].freeze

  belongs_to :product_registration, inverse_of: :publications
  belongs_to :channel_credential, optional: true

  validates :channel, presence: true, inclusion: { in: CHANNELS }
  validates :channel,
    uniqueness: { scope: :product_registration_id },
    unless: -> { channel_credential_id.present? }
  validates :channel_credential_id,
    uniqueness: { scope: :product_registration_id },
    allow_nil: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :channel_credential_matches_publication

  def destination_name
    channel_credential&.display_name || channel.to_s.humanize
  end

  private

  def channel_credential_matches_publication
    return unless channel_credential

    if channel_credential.tenant_id != product_registration&.tenant_id
      errors.add(:channel_credential, "deve pertencer à mesma empresa")
    end

    if channel_credential.channel != channel
      errors.add(:channel_credential, "deve ser do mesmo canal da publicação")
    end
  end
end
