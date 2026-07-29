require "rails_helper"

RSpec.describe Testimonials::DownloadTiktokVideoJob do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:url) { "https://www.tiktok.com/@usuario/video/1234567890" }

  def make_tiktok_testimonial(**overrides)
    tenant.testimonials.create!(
      { customer_name: "Ana", source_type: "tiktok", status: "draft", external_url: url }.merge(overrides)
    )
  end

  it "does nothing when the testimonial no longer exists" do
    expect { described_class.new.perform(0) }.not_to raise_error
  end

  it "does nothing when media is already attached (avoids reprocessing on retry)" do
    testimonial = make_tiktok_testimonial
    testimonial.media.attach(io: StringIO.new("x"), filename: "v.mp4", content_type: "video/mp4")

    expect(Testimonials::TiktokVideoDownloader).not_to receive(:call)

    described_class.new.perform(testimonial.id)
  end

  it "attaches the downloaded video and enqueues GenerateQuoteTextJob and GenerateThumbnailJob on success" do
    testimonial = make_tiktok_testimonial

    allow(Testimonials::TiktokVideoDownloader).to receive(:call).with(url).and_return(
      success: true, bytes: "fake-mp4-bytes", content_type: "video/mp4"
    )
    quote_text_ids = []
    thumbnail_ids = []
    allow(Testimonials::GenerateQuoteTextJob).to receive(:perform_later) { |id| quote_text_ids << id }
    allow(Testimonials::GenerateThumbnailJob).to receive(:perform_later) { |id| thumbnail_ids << id }

    described_class.new.perform(testimonial.id)

    expect(quote_text_ids).to eq([ testimonial.id ])
    expect(thumbnail_ids).to eq([ testimonial.id ])
    testimonial.reload
    expect(testimonial.media).to be_attached
    expect(testimonial.media.blob.content_type).to eq("video/mp4")
    expect(testimonial.media.download).to eq("fake-mp4-bytes")
  end

  it "does not attach anything or enqueue GenerateQuoteTextJob/GenerateThumbnailJob when the download fails" do
    testimonial = make_tiktok_testimonial

    allow(Testimonials::TiktokVideoDownloader).to receive(:call).and_return(
      success: false, error: "não foi possível baixar o vídeo do TikTok"
    )
    expect(Testimonials::GenerateQuoteTextJob).not_to receive(:perform_later)
    expect(Testimonials::GenerateThumbnailJob).not_to receive(:perform_later)

    described_class.new.perform(testimonial.id)

    expect(testimonial.reload.media).not_to be_attached
  end
end
