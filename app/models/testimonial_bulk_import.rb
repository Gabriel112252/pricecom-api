class TestimonialBulkImport < ApplicationRecord
  STATUSES = %w[pending processing done failed].freeze

  belongs_to :tenant
end
