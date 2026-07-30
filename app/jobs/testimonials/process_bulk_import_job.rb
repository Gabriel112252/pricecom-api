module Testimonials
  class ProcessBulkImportJob < ApplicationJob
    queue_as :integrations

    def perform(bulk_import_id)
      bulk_import = TestimonialBulkImport.find_by(id: bulk_import_id)
      return unless bulk_import

      zip_path = Rails.root.join("tmp", "testimonial_bulk_imports", bulk_import.filename)
      Testimonials::BulkImportService.new(bulk_import.tenant, zip_path.to_s, bulk_import).call
    end
  end
end
