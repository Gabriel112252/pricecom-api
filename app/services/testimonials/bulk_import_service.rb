require "csv"

module Testimonials
  # Cria dezenas/centenas de Testimonial de uma vez a partir de um ZIP:
  # um CSV (sku, customer_name, rating, quote_text, image_filename) na raiz
  # + as imagens soltas, também na raiz, referenciadas pelo nome exato no
  # CSV. Mesmo formato de progresso/relatório do Orders::ImportService
  # (status/total_rows/processed_rows/error_rows/errors_log) — ver
  # Testimonials::ProcessBulkImportJob/Api::V1::TestimonialsController#bulk_import.
  #
  # Diferença deliberada em relação ao Orders::ImportService: uma linha
  # ruim (SKU inexistente, imagem faltando, rating fora de 1..5...) vira UM
  # item em errors_log e o import CONTINUA — o pedido explícito desta
  # feature é "não abortar o import inteiro por uma linha ruim". status só
  # vira "failed" quando o ZIP/CSV inteiro é inutilizável (sem .csv, sem os
  # cabeçalhos esperados) — não quando algumas linhas falham.
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

          # Lê/escreve os bytes na mão (em vez de entry.extract) — o path
          # que entry.extract monta é relativo a destination_directory via
          # File.join, e um entry_path absoluto (o que dest é, vindo de um
          # Dir.mktmpdir) não vira um "replace", vira concatenação: dava um
          # path errado. Grava achatado (ignora qualquer subpasta do
          # entry.name) pra casar 1:1 com o índice de #index_images, mesmo
          # que o ZIP tenha sido gerado com estrutura de pastas por engano.
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
      # bom|utf-8: aceita CSV exportado do Excel com BOM UTF-8 (comum em
      # planilhas geradas no Windows) sem o BOM vazar pro nome da primeira
      # coluna do header.
      table = CSV.read(csv_path, headers: true, encoding: "bom|utf-8")

      missing_headers = REQUIRED_HEADERS - table.headers.to_a
      raise "Cabeçalho do CSV inválido — colunas faltando: #{missing_headers.join(', ')}" if missing_headers.any?

      @import.update!(total_rows: table.size)

      processed = 0
      errors = []

      table.each_with_index do |row, index|
        line_number = index + 2 # linha 1 é o header

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

      image_filename = row["image_filename"].to_s.strip
      image_path = images_index[image_filename]
      raise RowError, "Imagem não encontrada no ZIP: #{image_filename}" if image_path.nil?

      testimonial = @tenant.testimonials.new(
        customer_name: row["customer_name"].to_s.strip,
        rating: row["rating"].to_s.strip.presence&.to_i,
        quote_text: row["quote_text"].to_s.strip.presence,
        source_type: "manual",
        status: "draft"
      )

      # O file handle precisa continuar aberto até testimonial.save! — num
      # registro novo (ainda não persistido), Rails NÃO faz upload do blob
      # na hora do .attach, só na hora do save (upload adiado até ter um
      # record_id pra associar). Fechar o arquivo logo após o .attach
      # (ex: com File.open(...) { |f| ... }) fecha o stream antes do save
      # ler os bytes — daí o IOError "closed stream".
      file = File.open(image_path, "rb")
      begin
        # Sem content_type: — ActiveStorage detecta via Marcel a partir do
        # conteúdo/filename, mesma validação de formato do upload manual
        # (Testimonial#media_content_type_must_be_allowed) reaproveitada
        # abaixo pelo testimonial.save!.
        testimonial.media.attach(io: file, filename: File.basename(image_path))
        testimonial.product_ids = [ product.id ]
        testimonial.save!
      ensure
        file.close
      end
    end

    def error_message(error)
      return error.message if error.is_a?(RowError)

      error.record.errors.full_messages.join(", ")
    end
  end
end
