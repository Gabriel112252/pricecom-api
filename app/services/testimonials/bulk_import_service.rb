require "csv"
require "uri"

module Testimonials
  # Cria dezenas/centenas de Testimonial de uma vez a partir de um ZIP:
  # um CSV (sku, customer_name, rating, quote_text, image_filename) na raiz
  # + imagens opcionais, também na raiz, referenciadas pelo nome exato no
  # CSV. image_filename pode ficar vazio quando a avaliação não tem foto.
  #
  # Avaliações públicas de marketplaces também podem informar image_url.
  # Nesse caso a URL da foto original é preservada em tiktok_metadata como
  # external_image_url, evitando copiar o arquivo para o ActiveStorage local
  # do Sidekiq (API e worker rodam em containers/volumes separados).
  #
  # As colunas opcionais source_type e external_url preservam a origem real
  # (ex: mercadolivre) e o link público do conteúdo importado.
  #
  # Mesmo formato de progresso/relatório do Orders::ImportService
  # (status/total_rows/processed_rows/error_rows/errors_log) — ver
  # Testimonials::ProcessBulkImportJob/Api::V1::TestimonialsController#bulk_import.
  #
  # Uma linha ruim (SKU inexistente, imagem referenciada mas faltando,
  # rating fora de 1..5...) vira UM item em errors_log e o import CONTINUA.
  # status só vira "failed" quando o ZIP/CSV inteiro é inutilizável.
  class BulkImportService
    REQUIRED_HEADERS = %w[sku customer_name rating quote_text image_filename].freeze

    RowError = Class.new(StandardError)

    def initialize(tenant, zip_path, bulk_import)
      @tenant = tenant
      @zip_path = zip_path
      @import = bulk_import
    end

    def call
      @import.update!(status: "processing")

      Dir.mktmpdir("testimonial-bulk-import-") do |dir|
        extract_zip(dir)
        csv_path = find_csv(dir)
        raise "Nenhum arquivo .csv encontrado no ZIP" unless csv_path

        images_index = index_images(dir, csv_path)
        process_csv(csv_path, images_index)
      end
    rescue => e
      @import.update!(status: "failed", errors_log: [ { error: e.message } ], finished_at: Time.current)
    end

    private

    def extract_zip(dir)
      Zip::File.open(@zip_path) do |zip|
        zip.each do |entry|
          next if entry.directory?

          dest = File.join(dir, File.basename(entry.name))
          File.binwrite(dest, entry.get_input_stream.read)
        end
      end
    end

    def find_csv(dir)
      Dir.glob(File.join(dir, "*.{csv,CSV}")).min
    end

    def index_images(dir, csv_path)
      Dir.glob(File.join(dir, "*")).each_with_object({}) do |path, index|
        next if path == csv_path

        index[File.basename(path)] = path
      end
    end

    def process_csv(csv_path, images_index)
      table = CSV.read(csv_path, headers: true, encoding: "bom|utf-8")

      missing_headers = REQUIRED_HEADERS - table.headers.to_a
      raise "Cabeçalho do CSV inválido — colunas faltando: #{missing_headers.join(', ')}" if missing_headers.any?

      @import.update!(total_rows: table.size)

      processed = 0
      errors = []

      table.each_with_index do |row, index|
        line_number = index + 2

        begin
          import_row(row, images_index)
          processed += 1
        rescue RowError, ActiveRecord::RecordInvalid => e
          errors << { row: line_number, sku: row["sku"], error: error_message(e) }
        end

        attempted = index + 1
        @import.update!(processed_rows: processed, error_rows: errors.size) if (attempted % 50).zero? || attempted == table.size
      end

      @import.update!(
        status: "done",
        processed_rows: processed,
        error_rows: errors.size,
        errors_log: errors,
        finished_at: Time.current
      )
    end

    def import_row(row, images_index)
      sku = row["sku"].to_s.strip
      product = @tenant.products.find_by(sku: sku)
      raise RowError, "SKU não encontrado: #{sku}" if product.nil?

      source_type = row["source_type"].to_s.strip.presence || "manual"
      unless Testimonial::SOURCE_TYPES.include?(source_type)
        raise RowError, "Origem inválida: #{source_type}"
      end

      image_filename = row["image_filename"].to_s.strip.presence
      image_path = image_filename && images_index[image_filename]
      if image_filename && image_path.nil?
        raise RowError, "Imagem não encontrada no ZIP: #{image_filename}"
      end

      image_url = row["image_url"].to_s.strip.presence
      if image_url && !valid_http_url?(image_url)
        raise RowError, "URL de imagem inválida: #{image_url}"
      end

      metadata = {}
      metadata["external_image_url"] = image_url if image_url

      testimonial = @tenant.testimonials.new(
        customer_name: row["customer_name"].to_s.strip,
        rating: row["rating"].to_s.strip.presence&.to_i,
        quote_text: row["quote_text"].to_s.strip.presence,
        source_type: source_type,
        external_url: row["external_url"].to_s.strip.presence,
        tiktok_metadata: metadata,
        status: "draft"
      )
      testimonial.product_ids = [ product.id ]

      if image_path
        file = File.open(image_path, "rb")
        begin
          testimonial.media.attach(io: file, filename: File.basename(image_path))
          testimonial.save!
        ensure
          file.close
        end
      else
        testimonial.save!
      end
    end

    def valid_http_url?(value)
      uri = URI.parse(value)
      uri.is_a?(URI::HTTP) && uri.host.present?
    rescue URI::InvalidURIError
      false
    end

    def error_message(error)
      return error.message if error.is_a?(RowError)

      error.record.errors.full_messages.join(", ")
    end
  end
end
