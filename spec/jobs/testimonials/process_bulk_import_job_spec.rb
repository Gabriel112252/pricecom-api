require "rails_helper"

RSpec.describe Testimonials::ProcessBulkImportJob do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:bulk_import) { tenant.testimonial_bulk_imports.create!(filename: "lote.zip", status: "pending") }

  it "does nothing when the bulk import record no longer exists" do
    expect { described_class.new.perform(0) }.not_to raise_error
  end

  it "does nothing when no ZIP has been attached" do
    expect(Testimonials::BulkImportService).not_to receive(:new)

    described_class.new.perform(bulk_import.id)
  end

  it "downloads the attached ZIP (ActiveStorage) to a local tempfile and delegates processing to BulkImportService" do
    bulk_import.zip_file.attach(io: StringIO.new("fake-zip-bytes"), filename: "lote.zip", content_type: "application/zip")

    captured_path = nil
    service = instance_double(Testimonials::BulkImportService, call: true)
    allow(Testimonials::BulkImportService).to receive(:new) do |received_tenant, path, received_import|
      expect(received_tenant).to eq(tenant)
      expect(received_import).to eq(bulk_import)
      expect(File.exist?(path)).to be true
      expect(File.binread(path)).to eq("fake-zip-bytes")
      captured_path = path
      service
    end

    described_class.new.perform(bulk_import.id)

    expect(service).to have_received(:call)
    # zip_file.open baixa pra um tempfile local só durante o bloco — depois
    # do job terminar, o download não deve sobrar em disco.
    expect(File.exist?(captured_path)).to be false
  end
end
