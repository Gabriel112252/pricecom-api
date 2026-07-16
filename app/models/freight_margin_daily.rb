class FreightMarginDaily < ApplicationRecord
  belongs_to :tenant
  belongs_to :channel

  validates :date, presence: true, uniqueness: { scope: [ :tenant_id, :channel_id ] }
end
