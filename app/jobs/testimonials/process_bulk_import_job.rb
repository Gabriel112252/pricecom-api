require "open-uri"
require "tempfile"

module Testimonials
  class ProcessBulkImportJob < ApplicationJob
    queue_as :integrations

    def perform(bulk_import_id)
      bulk_import = TestimonialBulkImport.find_by(id: bulk_import_id)
      return unless bulk_import

      unless bulk_import.zip_file.attached?
        return fail_import!(bulk_import, "Arquivo ZIP não está anexado")
      end

      # Em produção API e Sidekiq são serviços separados no Easypanel. Mesmo
      # quando ambos possuem um volume chamado "active-storage", cada serviço
      # pode estar usando um volume Docker diferente. Por isso não podemos
      # chamar zip_file.open aqui: o blob foi gravado no disco da API e pode
      # não existir no filesystem do worker.
      #
      # O arquivo é baixado pela rota assinada do próprio ActiveStorage na API,
      # que é quem possui o blob local. O Sidekiq trabalha apenas com um
      # tempfile local durante este job.
      download_zip_from_api(bulk_import) do |zip_tempfile|
        Testimonials::BulkImportService.new(
          bulk_import.tenant,
          zip_tempfile.path,
          bulk_import
        ).call
      end
    rescue => e
      fail_import!(bulk_import, e.message) if bulk_import
    end

    private

    def download_zip_from_api(bulk_import)
      blob_path = Rails.application.routes.url_helpers.rails_blob_path(
        bulk_import.zip_file,
        only_path: true
      )
      app_host = ENV.fetch(
        "APP_HOST",
        "https://pricecom-pricecom-api.dzxtro.easypanel.host"
      ).sub(%r{/\z}, "")
      url = "#{app_host}#{blob_path}"

      URI.open(url, open_timeout: 10, read_timeout: 120) do |remote|
        Tempfile.create([ "testimonial-bulk-import-", ".zip" ]) do |tempfile|
          tempfile.binmode
          IO.copy_stream(remote, tempfile)
          tempfile.flush
          yield tempfile
        end
      end
    end

    def fail_import!(bulk_import, message)
      bulk_import.update!(
        status: "failed",
        errors_log: [ { error: message } ],
        finished_at: Time.current
      )
      Rails.logger.error(
        "[Testimonials::ProcessBulkImportJob] bulk_import=#{bulk_import.id} failed: #{message}"
      )
      nil
    end
  end
end
