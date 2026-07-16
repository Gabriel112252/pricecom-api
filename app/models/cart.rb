class Cart < ApplicationRecord
  STATUSES = %w[abandoned converted].freeze

  belongs_to :tenant
  belongs_to :channel
  belongs_to :converted_order, class_name: "Order", optional: true

  validates :external_id, presence: true, uniqueness: { scope: [ :tenant_id, :channel_id ] }
  validates :status, inclusion: { in: STATUSES }

  scope :abandoned, -> { where(status: "abandoned") }
  scope :converted, -> { where(status: "converted") }

  def mark_converted!(order)
    update!(status: "converted", converted_order: order)
  end
end
