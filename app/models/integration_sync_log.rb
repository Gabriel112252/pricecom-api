class IntegrationSyncLog < ApplicationRecord
  belongs_to :tenant
  belongs_to :integration, optional: true

  STATUSES    = %w[pending success error skipped].freeze
  DIRECTIONS  = %w[inbound outbound].freeze

  validates :direction, presence: true, inclusion: { in: DIRECTIONS }
  validates :action,    presence: true
  validates :status,    presence: true, inclusion: { in: STATUSES }

  scope :recent,    -> { order(created_at: :desc) }
  scope :succeeded, -> { where(status: "success") }
  scope :failed,    -> { where(status: "error") }
  scope :inbound,   -> { where(direction: "inbound") }
  scope :outbound,  -> { where(direction: "outbound") }

  def duration_from_timestamps
    return nil unless started_at && finished_at
    ((finished_at - started_at) * 1000).round
  end
end
