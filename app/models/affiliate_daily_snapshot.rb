class AffiliateDailySnapshot < ApplicationRecord
  belongs_to :tenant
  belongs_to :channel

  validates :snapshot_date, presence: true
end
