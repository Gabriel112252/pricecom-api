require "rails_helper"

RSpec.describe Testimonials::TiktokOembedFetcher do
  let(:url) { "https://www.tiktok.com/@usuario/video/1234567890" }

  describe ".call" do
    it "returns normalized metadata on a successful oEmbed response" do
      stub_request(:get, "https://www.tiktok.com/oembed").with(query: { url: url }).to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          title: "Vídeo incrível",
          author_name: "usuario",
          thumbnail_url: "https://p16-sign.tiktokcdn.com/thumb.jpeg",
          html: "<blockquote class=\"tiktok-embed\">...</blockquote>",
          ignored_field: "não deveria aparecer no resultado"
        }.to_json
      )

      result = described_class.call(url)

      expect(result).to eq(
        success: true,
        data: {
          "title" => "Vídeo incrível",
          "author_name" => "usuario",
          "thumbnail_url" => "https://p16-sign.tiktokcdn.com/thumb.jpeg",
          "html" => "<blockquote class=\"tiktok-embed\">...</blockquote>"
        }
      )
    end

    it "returns a generic error when TikTok responds with a non-200 status (e.g. link inválido/vídeo removido)" do
      stub_request(:get, "https://www.tiktok.com/oembed").with(query: { url: url }).to_return(status: 404, body: "Not Found")

      result = described_class.call(url)

      expect(result).to eq(success: false, error: "link inválido ou vídeo indisponível")
    end

    it "returns the same generic error on a timeout, without leaking the underlying exception" do
      stub_request(:get, "https://www.tiktok.com/oembed").with(query: { url: url }).to_timeout

      result = described_class.call(url)

      expect(result).to eq(success: false, error: "link inválido ou vídeo indisponível")
    end

    it "returns the same generic error on a connection failure" do
      stub_request(:get, "https://www.tiktok.com/oembed").with(query: { url: url }).to_raise(Faraday::ConnectionFailed)

      result = described_class.call(url)

      expect(result).to eq(success: false, error: "link inválido ou vídeo indisponível")
    end
  end
end
