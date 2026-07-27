require "rails_helper"

RSpec.describe Testimonials::GenerateQuoteTextJob do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }

  def make_testimonial(**overrides)
    tenant.testimonials.create!(
      { customer_name: "Ana", source_type: "manual", status: "draft" }.merge(overrides)
    )
  end

  it "does nothing when the testimonial no longer exists" do
    expect { described_class.new.perform(0) }.not_to raise_error
  end

  it "does nothing when quote_text is already present" do
    testimonial = make_testimonial(quote_text: "Já tenho um texto")
    testimonial.media.attach(io: StringIO.new("x"), filename: "foto.jpg", content_type: "image/jpeg")

    expect(Testimonials::FrameExtractor).not_to receive(:call)

    described_class.new.perform(testimonial.id)
  end

  it "does nothing when there is no media attached" do
    testimonial = make_testimonial

    expect(Testimonials::AnthropicVisionClient).not_to receive(:call)

    described_class.new.perform(testimonial.id)
  end

  it "fills quote_text with the generated suggestion" do
    testimonial = make_testimonial
    testimonial.media.attach(io: StringIO.new("fake-jpeg"), filename: "foto.jpg", content_type: "image/jpeg")

    allow(Testimonials::FrameExtractor).to receive(:call).and_return(bytes: "fake-jpeg", content_type: "image/jpeg")
    allow(Testimonials::AnthropicVisionClient).to receive(:call).with("fake-jpeg", "image/jpeg").and_return("Adorei o produto!")

    described_class.new.perform(testimonial.id)

    expect(testimonial.reload.quote_text).to eq("Adorei o produto!")
  end

  it "leaves quote_text blank when the vision client returns nothing" do
    testimonial = make_testimonial
    testimonial.media.attach(io: StringIO.new("fake-jpeg"), filename: "foto.jpg", content_type: "image/jpeg")

    allow(Testimonials::FrameExtractor).to receive(:call).and_return(bytes: "fake-jpeg", content_type: "image/jpeg")
    allow(Testimonials::AnthropicVisionClient).to receive(:call).and_return(nil)

    described_class.new.perform(testimonial.id)

    expect(testimonial.reload.quote_text).to be_nil
  end
end
