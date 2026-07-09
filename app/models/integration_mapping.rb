class IntegrationMapping < ApplicationRecord
  belongs_to :tenant
  belongs_to :integration
  belongs_to :mappable, polymorphic: true, optional: true

  STATUSES = %w[active inactive error].freeze

  validates :external_id,   presence: true
  validates :external_type, presence: true
  validates :status,        inclusion: { in: STATUSES }

  scope :active,          -> { where(status: "active") }
  scope :for_external,    ->(type, id) { where(external_type: type, external_id: id) }
  scope :for_mappable,    ->(record) { where(mappable: record) }
end
