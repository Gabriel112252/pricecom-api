class IntegrationEvent < ApplicationRecord
  belongs_to :tenant
  belongs_to :integration, optional: true

  STATUSES = %w[pending processing processed skipped error].freeze

  validates :provider,    presence: true
  validates :event_type,  presence: true
  validates :status,      inclusion: { in: STATUSES }

  scope :pending,     -> { where(status: "pending") }
  scope :processed,   -> { where(status: "processed") }
  scope :failed,      -> { where(status: "error") }
  scope :recent,      -> { order(received_at: :desc, created_at: :desc) }
  scope :by_provider, ->(p) { where(provider: p) }
end
