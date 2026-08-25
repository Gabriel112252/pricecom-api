class IntegrationEvent < ApplicationRecord
  belongs_to :tenant
  belongs_to :integration, optional: true
  belongs_to :channel_credential, optional: true

  STATUSES = %w[pending processing processed skipped error].freeze

  validates :provider,    presence: true
  validates :event_type,  presence: true
  validates :status,      inclusion: { in: STATUSES }
  validate :channel_credential_matches_event

  scope :pending,     -> { where(status: "pending") }
  scope :processed,   -> { where(status: "processed") }
  scope :failed,      -> { where(status: "error") }
  scope :recent,      -> { order(received_at: :desc, created_at: :desc) }
  scope :by_provider, ->(p) { where(provider: p) }

  private

  def channel_credential_matches_event
    return unless channel_credential

    errors.add(:channel_credential, "deve pertencer ao mesmo tenant") if channel_credential.tenant_id != tenant_id
    errors.add(:channel_credential, "deve ser do mesmo provider") if channel_credential.channel != provider
  end
end
