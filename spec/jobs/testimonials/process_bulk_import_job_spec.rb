require "rails_helper"

RSpec.describe Testimonials::ProcessBulkImportJob do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:bulk_import) { tenant.testimonial_bulk_imports.create!(filename: "abc123_lote.zip", status: "pending") }

  it "does nothing when the bulk import record no longer exists" do
    expect { described_class.new.perform(0) }.not_to raise_error
  end

  it "resolves the uploaded file path and delegates processing to BulkImportService" do
    expected_path = Rails.root.join("tmp", "testimonial_bulk_imports", "abc123_lote.zip").to_s
    service = instance_double(Testimonials::BulkImportService, call: true)

    expect(Testimonials::BulkImportService).to receive(:new)
      .with(tenant, expected_path, bulk_import)
      .and_return(service)

    described_class.new.perform(bulk_import.id)

    expect(service).to have_received(:call)
  end
end
