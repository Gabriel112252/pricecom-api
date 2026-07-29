require "rails_helper"

RSpec.describe Testimonial do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }

  def make_testimonial(**overrides)
    tenant.testimonials.new(
      { customer_name: "Ana", source_type: "manual", status: "draft", quote_text: "Ótimo!" }.merge(overrides)
    )
  end

  describe "products" do
    let(:product_a) { tenant.products.create!(sku: "SKU-A", name: "Produto A", cost_price: 10) }
    let(:product_b) { tenant.products.create!(sku: "SKU-B", name: "Produto B", cost_price: 10) }

    it "can be linked to more than one product" do
      testimonial = tenant.testimonials.create!(customer_name: "Ana", source_type: "manual", status: "draft")

      testimonial.product_ids = [ product_a.id, product_b.id ]

      expect(testimonial.reload.products).to contain_exactly(product_a, product_b)
    end

    it "is valid with no product linked at all (rating/media-only testimonial)" do
      testimonial = make_testimonial

      expect(testimonial).to be_valid
      expect(testimonial.products).to eq([])
    end

    it "rejects a product that belongs to a different tenant" do
      other_tenant = Tenant.create!(name: "Outra Loja", slug: "outra-#{SecureRandom.hex(4)}")
      other_product = other_tenant.products.create!(sku: "SKU-X", name: "Produto X", cost_price: 10)
      testimonial = tenant.testimonials.create!(customer_name: "Ana", source_type: "manual", status: "draft")

      expect { testimonial.product_ids = [ other_product.id ] }
        .to raise_error(ActiveRecord::RecordInvalid, /inválido/)
      expect(testimonial.reload.products).to eq([])
    end

    it "removing a testimonial destroys its testimonial_products rows too" do
      testimonial = tenant.testimonials.create!(customer_name: "Ana", source_type: "manual", status: "draft")
      testimonial.product_ids = [ product_a.id ]

      expect { testimonial.destroy! }.to change(TestimonialProduct, :count).by(-1)
    end
  end

  describe "quote_text" do
    it "is optional in every status — a testimonial can be rating/media-only" do
      testimonial = make_testimonial(quote_text: nil, status: "draft")
      expect(testimonial).to be_valid

      testimonial.status = "approved"
      expect(testimonial).to be_valid

      testimonial.status = "published"
      expect(testimonial).to be_valid
    end
  end

  describe "media content type" do
    it "is valid without any media attached" do
      expect(make_testimonial).to be_valid
    end

    it "accepts common image formats" do
      testimonial = make_testimonial
      testimonial.media.attach(io: StringIO.new("fake"), filename: "foto.jpg", content_type: "image/jpeg")

      expect(testimonial).to be_valid
    end

    it "accepts common video formats (mp4, mov, webm)" do
      %w[video/mp4 video/quicktime video/webm].each do |content_type|
        testimonial = make_testimonial
        testimonial.media.attach(io: StringIO.new("fake"), filename: "video", content_type: content_type)

        expect(testimonial).to be_valid, "esperava #{content_type} válido, erros: #{testimonial.errors.full_messages}"
      end
    end

    it "rejects an unsupported content type" do
      testimonial = make_testimonial
      testimonial.media.attach(io: StringIO.new("fake"), filename: "malware.exe", content_type: "application/x-msdownload")

      expect(testimonial).not_to be_valid
      expect(testimonial.errors[:media]).to be_present
    end
  end
end
