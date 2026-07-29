require "rails_helper"

RSpec.describe Testimonials::GenerateThumbnailJob do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }

  def make_testimonial(**overrides)
    tenant.testimonials.create!(
      { customer_name: "Ana", source_type: "manual", status: "draft" }.merge(overrides)
    )
  end

  it "does nothing when the testimonial no longer exists" do
    expect { described_class.new.perform(0) }.not_to raise_error
  end

  it "does nothing when there is no media attached" do
    testimonial = make_testimonial

    expect(Testimonials::FrameExtractor).not_to receive(:call)

    described_class.new.perform(testimonial.id)
  end

  it "does nothing for image media — does not call FrameExtractor (no ffmpeg work needed)" do
    testimonial = make_testimonial
    testimonial.media.attach(io: StringIO.new("fake-jpeg"), filename: "foto.jpg", content_type: "image/jpeg")

    expect(Testimonials::FrameExtractor).not_to receive(:call)

    described_class.new.perform(testimonial.id)

    expect(testimonial.reload.thumbnail).not_to be_attached
  end

  it "does nothing when a thumbnail is already attached (avoids reprocessing on retry)" do
    testimonial = make_testimonial(source_type: "tiktok", external_url: "https://www.tiktok.com/@u/video/1")
    testimonial.media.attach(io: StringIO.new("fake-mp4"), filename: "v.mp4", content_type: "video/mp4")
    testimonial.thumbnail.attach(io: StringIO.new("already-there"), filename: "thumb.jpg", content_type: "image/jpeg")

    expect(Testimonials::FrameExtractor).not_to receive(:call)

    described_class.new.perform(testimonial.id)
  end

  it "extracts a frame and attaches it as thumbnail for a manual video testimonial" do
    testimonial = make_testimonial
    testimonial.media.attach(io: StringIO.new("fake-mp4"), filename: "v.mp4", content_type: "video/mp4")

    allow(Testimonials::FrameExtractor).to receive(:call)
      .and_return(bytes: "fake-frame-bytes", content_type: "image/jpeg")

    described_class.new.perform(testimonial.id)

    testimonial.reload
    expect(testimonial.thumbnail).to be_attached
    expect(testimonial.thumbnail.blob.content_type).to eq("image/jpeg")
    expect(testimonial.thumbnail.download).to eq("fake-frame-bytes")
  end

  it "extracts a frame and attaches it as thumbnail for a tiktok video testimonial" do
    testimonial = make_testimonial(source_type: "tiktok", external_url: "https://www.tiktok.com/@u/video/1")
    testimonial.media.attach(io: StringIO.new("fake-mp4"), filename: "v.mp4", content_type: "video/mp4")

    allow(Testimonials::FrameExtractor).to receive(:call)
      .and_return(bytes: "fake-frame-bytes", content_type: "image/jpeg")

    described_class.new.perform(testimonial.id)

    expect(testimonial.reload.thumbnail).to be_attached
  end

  it "leaves thumbnail unattached when frame extraction fails" do
    testimonial = make_testimonial
    testimonial.media.attach(io: StringIO.new("fake-mp4"), filename: "v.mp4", content_type: "video/mp4")

    allow(Testimonials::FrameExtractor).to receive(:call).and_return(nil)

    described_class.new.perform(testimonial.id)

    expect(testimonial.reload.thumbnail).not_to be_attached
  end
end
