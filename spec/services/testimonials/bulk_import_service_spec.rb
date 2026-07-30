require "rails_helper"

RSpec.describe Testimonials::BulkImportService do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let!(:product_a) { tenant.products.create!(sku: "SKU-A", name: "Produto A", cost_price: 10) }
  let!(:product_b) { tenant.products.create!(sku: "SKU-B", name: "Produto B", cost_price: 5) }
  let(:bulk_import) { tenant.testimonial_bulk_imports.create!(filename: "import.zip", status: "pending") }

  def jpeg_bytes
    Rails.root.join("spec/fixtures/files/testimonial_photo.jpg").binread
  end

  # images: { "nome do arquivo.jpg" => bytes }. csv_filename permite testar
  # "o primeiro .csv encontrado" com um nome que não seja sempre igual.
  def build_zip(csv:, images: {}, csv_filename: "import.csv")
    path = Rails.root.join("tmp", "spec-bulk-import-#{SecureRandom.hex(8)}.zip")
    Zip::File.open(path.to_s, create: true) do |zip|
      zip.get_output_stream(csv_filename) { |f| f.write(csv) }
      images.each { |filename, bytes| zip.get_output_stream(filename) { |f| f.write(bytes) } }
    end
    path.to_s
  end

  def valid_csv(rows)
    header = "sku,customer_name,rating,quote_text,image_filename"
    ([ header ] + rows).join("\n")
  end

  after do
    Dir.glob(Rails.root.join("tmp", "spec-bulk-import-*.zip")).each { |f| File.delete(f) }
  end

  it "imports every valid row as a draft testimonial linked to its product, with the image attached" do
    csv = valid_csv([
      "SKU-A,Ana,5,Adorei!,foto1.jpg",
      "SKU-B,Bia,4,Muito bom,foto2.jpg"
    ])
    zip_path = build_zip(csv: csv, images: { "foto1.jpg" => jpeg_bytes, "foto2.jpg" => jpeg_bytes })

    expect {
      described_class.new(tenant, zip_path, bulk_import).call
    }.to change(Testimonial, :count).by(2)

    bulk_import.reload
    expect(bulk_import.status).to eq("done")
    expect(bulk_import.total_rows).to eq(2)
    expect(bulk_import.processed_rows).to eq(2)
    expect(bulk_import.error_rows).to eq(0)
    expect(bulk_import.errors_log).to eq([])

    ana = tenant.testimonials.find_by(customer_name: "Ana")
    expect(ana.status).to eq("draft")
    expect(ana.source_type).to eq("manual")
    expect(ana.rating).to eq(5)
    expect(ana.quote_text).to eq("Adorei!")
    expect(ana.product_ids).to eq([ product_a.id ])
    expect(ana.media).to be_attached
  end

  it "never publishes imported testimonials automatically, even for a fully successful batch" do
    csv = valid_csv([ "SKU-A,Ana,5,Adorei!,foto1.jpg" ])
    zip_path = build_zip(csv: csv, images: { "foto1.jpg" => jpeg_bytes })

    described_class.new(tenant, zip_path, bulk_import).call

    expect(Testimonial.pluck(:status)).to eq([ "draft" ])
  end

  it "logs a per-row error and keeps processing the rest when a SKU doesn't exist" do
    csv = valid_csv([
      "SKU-DOES-NOT-EXIST,Ana,5,Adorei!,foto1.jpg",
      "SKU-B,Bia,4,Muito bom,foto2.jpg"
    ])
    zip_path = build_zip(csv: csv, images: { "foto1.jpg" => jpeg_bytes, "foto2.jpg" => jpeg_bytes })

    expect {
      described_class.new(tenant, zip_path, bulk_import).call
    }.to change(Testimonial, :count).by(1)

    bulk_import.reload
    expect(bulk_import.status).to eq("done")
    expect(bulk_import.total_rows).to eq(2)
    expect(bulk_import.processed_rows).to eq(1)
    expect(bulk_import.error_rows).to eq(1)
    expect(bulk_import.errors_log).to eq([
      { "row" => 2, "sku" => "SKU-DOES-NOT-EXIST", "error" => "SKU não encontrado: SKU-DOES-NOT-EXIST" }
    ])
    expect(tenant.testimonials.pluck(:customer_name)).to eq([ "Bia" ])
  end

  it "logs a per-row error and keeps processing when the CSV references an image missing from the ZIP" do
    csv = valid_csv([
      "SKU-A,Ana,5,Adorei!,nao-existe.jpg",
      "SKU-B,Bia,4,Muito bom,foto2.jpg"
    ])
    zip_path = build_zip(csv: csv, images: { "foto2.jpg" => jpeg_bytes })

    described_class.new(tenant, zip_path, bulk_import).call

    bulk_import.reload
    expect(bulk_import.processed_rows).to eq(1)
    expect(bulk_import.error_rows).to eq(1)
    expect(bulk_import.errors_log).to eq([
      { "row" => 2, "sku" => "SKU-A", "error" => "Imagem não encontrada no ZIP: nao-existe.jpg" }
    ])
    expect(tenant.testimonials.pluck(:customer_name)).to eq([ "Bia" ])
  end

  it "handles image filenames with spaces and parentheses correctly" do
    csv = valid_csv([ "SKU-A,Ana,5,Adorei!,foto (1).jpg" ])
    zip_path = build_zip(csv: csv, images: { "foto (1).jpg" => jpeg_bytes })

    described_class.new(tenant, zip_path, bulk_import).call

    bulk_import.reload
    expect(bulk_import.error_rows).to eq(0)
    testimonial = tenant.testimonials.find_by(customer_name: "Ana")
    expect(testimonial.media).to be_attached
    expect(testimonial.media.filename.to_s).to eq("foto (1).jpg")
  end

  it "fails the whole import (without processing any row) when the CSV headers are wrong" do
    csv = "product_sku,name,stars,text,image\nSKU-A,Ana,5,Adorei!,foto1.jpg"
    zip_path = build_zip(csv: csv, images: { "foto1.jpg" => jpeg_bytes })

    expect {
      described_class.new(tenant, zip_path, bulk_import).call
    }.not_to change(Testimonial, :count)

    bulk_import.reload
    expect(bulk_import.status).to eq("failed")
    expect(bulk_import.errors_log.first["error"]).to match(/Cabeçalho do CSV inválido/)
  end

  it "fails the whole import when the ZIP has no .csv file at all" do
    path = Rails.root.join("tmp", "spec-bulk-import-#{SecureRandom.hex(8)}.zip")
    Zip::File.open(path.to_s, create: true) { |zip| zip.get_output_stream("foto1.jpg") { |f| f.write(jpeg_bytes) } }

    described_class.new(tenant, path.to_s, bulk_import).call

    bulk_import.reload
    expect(bulk_import.status).to eq("failed")
    expect(bulk_import.errors_log.first["error"]).to match(/Nenhum arquivo \.csv encontrado/)
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  it "picks the first .csv found regardless of its name" do
    csv = valid_csv([ "SKU-A,Ana,5,Adorei!,foto1.jpg" ])
    zip_path = build_zip(csv: csv, images: { "foto1.jpg" => jpeg_bytes }, csv_filename: "depoimentos_lote_3.csv")

    described_class.new(tenant, zip_path, bulk_import).call

    expect(bulk_import.reload.status).to eq("done")
    expect(tenant.testimonials.count).to eq(1)
  end

  it "logs a per-row error for a rating out of range instead of aborting the batch" do
    csv = valid_csv([
      "SKU-A,Ana,9,Nota inválida,foto1.jpg",
      "SKU-B,Bia,4,Muito bom,foto2.jpg"
    ])
    zip_path = build_zip(csv: csv, images: { "foto1.jpg" => jpeg_bytes, "foto2.jpg" => jpeg_bytes })

    described_class.new(tenant, zip_path, bulk_import).call

    bulk_import.reload
    expect(bulk_import.processed_rows).to eq(1)
    expect(bulk_import.error_rows).to eq(1)
    expect(bulk_import.errors_log.first["row"]).to eq(2)
    expect(tenant.testimonials.pluck(:customer_name)).to eq([ "Bia" ])
  end

  it "only links the product to the tenant that owns the import, never a same-SKU product from another tenant" do
    other_tenant = Tenant.create!(name: "Outra Loja", slug: "outra-#{SecureRandom.hex(4)}")
    other_tenant.products.create!(sku: "SKU-A", name: "Produto A de outra loja", cost_price: 1)

    csv = valid_csv([ "SKU-A,Ana,5,Adorei!,foto1.jpg" ])
    zip_path = build_zip(csv: csv, images: { "foto1.jpg" => jpeg_bytes })

    described_class.new(tenant, zip_path, bulk_import).call

    testimonial = tenant.testimonials.find_by(customer_name: "Ana")
    expect(testimonial.products).to eq([ product_a ])
  end
end
