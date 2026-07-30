require "rails_helper"

RSpec.describe "Testimonials bulk import", type: :request do
  let(:tenant)   { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:admin)    { tenant.users.create!(name: "Admin", email: "admin@#{SecureRandom.hex(4)}.com", password: "password123", role: "admin") }
  let(:operador) { tenant.users.create!(name: "Operador", email: "op@#{SecureRandom.hex(4)}.com", password: "password123", role: "operador") }

  def auth_headers(user)
    { "Authorization" => "Bearer #{JsonWebToken.encode(user_id: user.id)}" }
  end

  def build_zip
    path = Rails.root.join("tmp", "spec-bulk-import-req-#{SecureRandom.hex(8)}.zip")
    Zip::File.open(path.to_s, create: true) do |zip|
      zip.get_output_stream("import.csv") { |f| f.write("sku,customer_name,rating,quote_text,image_filename\n") }
    end
    Rack::Test::UploadedFile.new(path.to_s, "application/zip")
  end

  describe "POST /api/v1/testimonials/bulk_import" do
    it "requires admin" do
      post "/api/v1/testimonials/bulk_import", params: { file: build_zip }, headers: auth_headers(operador)
      expect(response).to have_http_status(:forbidden)
    end

    it "requires a file" do
      post "/api/v1/testimonials/bulk_import", headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to be_present
    end

    it "creates a pending TestimonialBulkImport, attaches the ZIP via ActiveStorage, enqueues the job, and responds immediately" do
      enqueued_ids = []
      allow(Testimonials::ProcessBulkImportJob).to receive(:perform_later) { |id| enqueued_ids << id }

      post "/api/v1/testimonials/bulk_import", params: { file: build_zip }, headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
      bulk_import = tenant.testimonial_bulk_imports.last
      expect(bulk_import.status).to eq("pending")
      # ActiveStorage, não um path em tmp/ — o job roda num container
      # (Sidekiq) separado do que recebeu esta request, sem filesystem
      # local compartilhado (ver Testimonials::ProcessBulkImportJob).
      expect(bulk_import.zip_file).to be_attached
      expect(enqueued_ids).to eq([ bulk_import.id ])

      body = JSON.parse(response.body)
      expect(body["id"]).to eq(bulk_import.id)
      expect(body["status"]).to eq("pending")
    end

    it "does not process synchronously — the job is only enqueued, not run inline" do
      expect(Testimonials::BulkImportService).not_to receive(:new)
      allow(Testimonials::ProcessBulkImportJob).to receive(:perform_later)

      post "/api/v1/testimonials/bulk_import", params: { file: build_zip }, headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
    end
  end

  describe "GET /api/v1/testimonials/bulk_import/:id" do
    it "requires admin" do
      bulk_import = tenant.testimonial_bulk_imports.create!(filename: "x.zip", status: "processing")
      get "/api/v1/testimonials/bulk_import/#{bulk_import.id}", headers: auth_headers(operador)
      expect(response).to have_http_status(:forbidden)
    end

    it "returns the current progress while still processing" do
      bulk_import = tenant.testimonial_bulk_imports.create!(
        filename: "x.zip", status: "processing", total_rows: 100, processed_rows: 40, error_rows: 2
      )

      get "/api/v1/testimonials/bulk_import/#{bulk_import.id}", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body).to include(
        "id" => bulk_import.id, "status" => "processing",
        "total_rows" => 100, "processed_rows" => 40, "error_rows" => 2
      )
    end

    it "returns the full per-row report once done" do
      bulk_import = tenant.testimonial_bulk_imports.create!(
        filename: "x.zip", status: "done", total_rows: 2, processed_rows: 1, error_rows: 1,
        errors_log: [ { row: 3, sku: "SKU-X", error: "SKU não encontrado: SKU-X" } ],
        finished_at: Time.current
      )

      get "/api/v1/testimonials/bulk_import/#{bulk_import.id}", headers: auth_headers(admin)

      body = JSON.parse(response.body)
      expect(body["status"]).to eq("done")
      expect(body["errors"]).to eq([ { "row" => 3, "sku" => "SKU-X", "error" => "SKU não encontrado: SKU-X" } ])
      expect(body["finished_at"]).to be_present
    end

    it "does not leak cross-tenant bulk imports" do
      other_tenant = Tenant.create!(name: "Outra Loja", slug: "outra-#{SecureRandom.hex(4)}")
      other_import = other_tenant.testimonial_bulk_imports.create!(filename: "x.zip", status: "done")

      get "/api/v1/testimonials/bulk_import/#{other_import.id}", headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
    end
  end

  # Regressão do bug real: o processo que recebe o upload (pricecom-api)
  # e o que roda o job (pricecom-sidekiq) são containers separados, sem
  # filesystem local compartilhado — salvar em tmp/ no controller e ler do
  # mesmo tmp/ no job (como era antes) dava "File not found" em produção.
  # perform_now aqui roda o job de verdade (não um mock de
  # perform_later) — a mesma leitura via ActiveStorage que ele faz é
  # idêntica não importa em qual processo/container ela rode.
  describe "end-to-end: real ActiveStorage upload followed by a real (perform_now) job run" do
    let!(:product) { tenant.products.create!(sku: "SKU-A", name: "Produto A", cost_price: 10) }

    def build_real_zip
      jpeg_bytes = Rails.root.join("spec/fixtures/files/testimonial_photo.jpg").binread
      csv = "sku,customer_name,rating,quote_text,image_filename\nSKU-A,Ana,5,Adorei!,foto1.jpg"
      path = Rails.root.join("tmp", "spec-bulk-import-e2e-#{SecureRandom.hex(8)}.zip")
      Zip::File.open(path.to_s, create: true) do |zip|
        zip.get_output_stream("import.csv") { |f| f.write(csv) }
        zip.get_output_stream("foto1.jpg") { |f| f.write(jpeg_bytes) }
      end
      Rack::Test::UploadedFile.new(path.to_s, "application/zip")
    end

    it "processes the ZIP correctly with zero reliance on a local tmp/ path shared between request and job" do
      legacy_upload_dir = Rails.root.join("tmp", "testimonial_bulk_imports")
      FileUtils.rm_rf(legacy_upload_dir)

      post "/api/v1/testimonials/bulk_import", params: { file: build_real_zip }, headers: auth_headers(admin)
      expect(response).to have_http_status(:created)
      bulk_import_id = JSON.parse(response.body)["id"]

      Testimonials::ProcessBulkImportJob.perform_now(bulk_import_id)

      bulk_import = TestimonialBulkImport.find(bulk_import_id)
      expect(bulk_import.status).to eq("done")
      expect(bulk_import.total_rows).to eq(1)
      expect(bulk_import.processed_rows).to eq(1)
      expect(bulk_import.error_rows).to eq(0)

      testimonial = tenant.testimonials.find_by(customer_name: "Ana")
      expect(testimonial).to be_present
      expect(testimonial.status).to eq("draft")
      expect(testimonial.product_ids).to eq([ product.id ])
      expect(testimonial.media).to be_attached

      # A prova de que nada dependeu de filesystem local compartilhado: o
      # path antigo (o bug original) nunca foi criado nem tocado.
      expect(Dir.exist?(legacy_upload_dir)).to be false
    end
  end
end
