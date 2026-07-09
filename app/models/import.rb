class Import < ApplicationRecord
  belongs_to :tenant
  belongs_to :channel, optional: true

  STATUSES = %w[pending processing done failed].freeze
end
