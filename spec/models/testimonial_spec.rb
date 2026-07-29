require "rails_helper"

RSpec.describe Testimonial do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }

  def make_testimonial(**overrides)
    tenant.testimonials.new(
      { customer_name: "Ana", source_type: "manual", status: "draft", quote_text: "Ótimo!" }.merge(overrides)
    )
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
