require "rails_helper"

RSpec.describe Testimonials::TiktokVideoDownloader do
  let(:url) { "https://www.tiktok.com/@usuario/video/1234567890" }

  describe ".call" do
    it "downloads and returns the video bytes on success" do
      allow(Testimonials::ShellCommand).to receive(:run) do |*_args, **_kwargs|
        # yt-dlp would have written the file to the --output path; simulate that here
        output_index = _args.index("--output")
        template = _args[output_index + 1]
        File.write(template.sub("%(ext)s", "mp4"), "fake-mp4-bytes")
        Testimonials::ShellCommand::Result.new(success?: true, stdout: "", stderr: "")
      end

      result = described_class.call(url)

      expect(result).to eq(success: true, bytes: "fake-mp4-bytes", content_type: "video/mp4")
    end

    it "returns a generic error when yt-dlp fails" do
      allow(Testimonials::ShellCommand).to receive(:run).and_return(
        Testimonials::ShellCommand::Result.new(success?: false, stdout: "", stderr: "ERROR: video unavailable")
      )

      result = described_class.call(url)

      expect(result).to eq(success: false, error: "não foi possível baixar o vídeo do TikTok")
    end

    it "returns a generic error when yt-dlp succeeds but no file is produced" do
      allow(Testimonials::ShellCommand).to receive(:run).and_return(
        Testimonials::ShellCommand::Result.new(success?: true, stdout: "", stderr: "")
      )

      result = described_class.call(url)

      expect(result[:success]).to eq(false)
    end
  end
end
