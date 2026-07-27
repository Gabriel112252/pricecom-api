require "rails_helper"

RSpec.describe Testimonials::FrameExtractor do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:testimonial) { tenant.testimonials.create!(customer_name: "Ana", source_type: "manual", status: "draft", quote_text: "x") }

  describe ".call" do
    it "returns nil when no media is attached" do
      expect(described_class.call(testimonial.media)).to be_nil
    end

    it "returns the original bytes directly when the media is an image (no ffmpeg call)" do
      testimonial.media.attach(io: StringIO.new("fake-jpeg"), filename: "foto.jpg", content_type: "image/jpeg")
      expect(Testimonials::ShellCommand).not_to receive(:run)

      result = described_class.call(testimonial.media)

      expect(result).to eq(bytes: "fake-jpeg", content_type: "image/jpeg")
    end

    it "extracts a frame via ffmpeg when the media is a video" do
      testimonial.media.attach(io: StringIO.new("fake-mp4"), filename: "video.mp4", content_type: "video/mp4")

      allow(Testimonials::ShellCommand).to receive(:run) do |*args, **_kwargs|
        frame_path = args.last
        File.binwrite(frame_path, "fake-jpeg-frame")
        Testimonials::ShellCommand::Result.new(success?: true, stdout: "", stderr: "")
      end

      result = described_class.call(testimonial.media)

      expect(result).to eq(bytes: "fake-jpeg-frame", content_type: "image/jpeg")
    end

    it "returns nil when ffmpeg fails" do
      testimonial.media.attach(io: StringIO.new("fake-mp4"), filename: "video.mp4", content_type: "video/mp4")
      allow(Testimonials::ShellCommand).to receive(:run).and_return(
        Testimonials::ShellCommand::Result.new(success?: false, stdout: "", stderr: "invalid data")
      )

      expect(described_class.call(testimonial.media)).to be_nil
    end
  end
end
