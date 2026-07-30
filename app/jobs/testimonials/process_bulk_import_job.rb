module Testimonials
  class ProcessBulkImportJob < ApplicationJob
    queue_as :integrations

    def perform(bulk_import_id)
      bulk_import = TestimonialBulkImport.find_by(id: bulk_import_id)
      return unless bulk_import
      return unless bulk_import.zip_file.attached?

      # zip_file.open baixa o blob do ActiveStorage (o mesmo mecanismo já
      # usado por Testimonials::FrameExtractor pra ler #media entre web e
      # sidekiq) pra um tempfile LOCAL a este processo/container — só o
      # tempo do bloco, com cleanup automático (fecha e unlink) ao sair,
      # mesmo se BulkImportService levantar. Nada em tmp/ sobrevive além
      # deste job.
      bulk_import.zip_file.open do |zip_tempfile|
        Testimonials::BulkImportService.new(bulk_import.tenant, zip_tempfile.path, bulk_import).call
      end
    end
  end
end
