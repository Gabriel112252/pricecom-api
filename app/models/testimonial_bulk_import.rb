class TestimonialBulkImport < ApplicationRecord
  STATUSES = %w[pending processing done failed].freeze

  belongs_to :tenant

  # ActiveStorage (não um path em tmp/) — quem recebe o upload
  # (Api::V1::TestimonialsController#bulk_import) e quem processa
  # (Testimonials::ProcessBulkImportJob, via Sidekiq) rodam em containers
  # separados, sem filesystem local compartilhado. ActiveStorage local já é
  # comprovadamente acessível dos dois lados (mesmo mecanismo que
  # Testimonial#media/#thumbnail usam entre web e sidekiq).
  has_one_attached :zip_file
end
