require "rails_helper"

# Shapes from the Partner Center API reference (2026-11-25):
# get-shop-video-performance-list-202605 and
# get-shop-videos-performance-details-202609 — not yet confirmed against a
# real Hidrabene call.
RSpec.describe Integrations::TiktokAdapter, "shop videos" do
  let(:credentials) { { app_key: "key123", app_secret: "secret456", access_token: "tok789", shop_cipher: "GCP_cipher" } }
  let(:adapter) { described_class.new(credentials) }
  let(:list_url) { "https://open-api.tiktokglobalshop.com/analytics/202605/shop_videos/performance" }
  let(:details_url) { "https://open-api.tiktokglobalshop.com/analytics/202609/shop_videos/batch_performance" }
  let(:json_headers) { { "Content-Type" => "application/json" } }

  describe "#fetch_shop_videos" do
    let(:list_body) do
      {
        code: 0,
        message: "Success",
        data: {
          latest_available_date: "2026-11-24",
          next_page_token: "cGFnZT0y",
          total_count: 1,
          videos: [
            {
              id: "7300000000000000001",
              title: "Meu skincare",
              username: "criadora_a",
              duration: 34,
              video_post_time: "2026-11-20 10:00:00",
              creator: { author_type: "AFFILIATE", open_id: "uOPEN1", user_name: "criadora_a", nick_name: "Criadora A" },
              products: [ { id: "1729", name: "Sérum" } ],
              views: 1200
            }
          ]
        }
      }.to_json
    end

    it "sends the window as query params (inclusive date_to → exclusive end_date_lt), the account type and the shop cipher" do
      captured_request = nil
      stub_request(:get, /\A#{Regexp.escape(list_url)}/)
        .with { |request| captured_request = request }
        .to_return(status: 200, body: list_body, headers: json_headers)

      data = adapter.fetch_shop_videos(date_from: Date.new(2026, 10, 1), date_to: Date.new(2026, 11, 24), page_token: "abc")

      query = Rack::Utils.parse_query(captured_request.uri.query)
      expect(query).to include(
        "start_date_ge" => "2026-10-01",
        "end_date_lt" => "2026-11-25",
        "account_type" => "AFFILIATE_ACCOUNTS",
        "page_size" => "100",
        "page_token" => "abc",
        "currency" => "LOCAL",
        "shop_cipher" => "GCP_cipher"
      )
      expect(query).to include("sign", "timestamp")
      expect(captured_request.headers["X-Tts-Access-Token"]).to eq("tok789")
      expect(data["next_page_token"]).to eq("cGFnZT0y")
      expect(data.dig("videos", 0, "creator", "open_id")).to eq("uOPEN1")
    end

    it "omits page_token on the first page" do
      captured_request = nil
      stub_request(:get, /\A#{Regexp.escape(list_url)}/)
        .with { |request| captured_request = request }
        .to_return(status: 200, body: list_body, headers: json_headers)

      adapter.fetch_shop_videos(date_from: Date.new(2026, 11, 1), date_to: Date.new(2026, 11, 24))

      expect(Rack::Utils.parse_query(captured_request.uri.query)).not_to have_key("page_token")
    end

    it "refuses a window wider than 60 days before calling TikTok" do
      expect {
        adapter.fetch_shop_videos(date_from: Date.new(2026, 1, 1), date_to: Date.new(2026, 3, 2))
      }.to raise_error(ArgumentError, /60 dias/)
    end

    it "raises AuthenticationError with a scope hint when the analytics scope isn't granted" do
      stub_request(:get, /\A#{Regexp.escape(list_url)}/)
        .to_return(status: 200, body: { code: 105_005, message: "No permission to call this api" }.to_json, headers: json_headers)

      expect { adapter.fetch_shop_videos(date_from: Date.new(2026, 11, 1), date_to: Date.new(2026, 11, 24)) }
        .to raise_error(Integrations::AuthenticationError, /escopo/)
    end
  end

  describe "#fetch_shop_video_details" do
    let(:details_body) do
      {
        code: 0,
        message: "Success",
        data: {
          videos: [
            {
              video_id: "7300000000000000001",
              video: {
                id: "7300000000000000001",
                play_url: "https://cdn.example.com/v/abc.mp4?sig=1",
                thumbnail_url: "https://cdn.example.com/t/abc.jpg",
                duration: 34,
                title: "Meu skincare",
                username: "criadora_a",
                video_post_time: "1763632800"
              }
            }
          ]
        }
      }.to_json
    end

    it "sends video_ids as a bracketed list and returns the videos array" do
      captured_request = nil
      stub_request(:get, /\A#{Regexp.escape(details_url)}/)
        .with { |request| captured_request = request }
        .to_return(status: 200, body: details_body, headers: json_headers)

      videos = adapter.fetch_shop_video_details(
        video_ids: [ "7300000000000000001", 7300000000000000002 ],
        date_from: Date.new(2026, 9, 26),
        date_to: Date.new(2026, 11, 24)
      )

      query = Rack::Utils.parse_query(captured_request.uri.query)
      expect(query).to include(
        "video_ids" => "[7300000000000000001,7300000000000000002]",
        "start_date_ge" => "2026-09-26",
        "end_date_lt" => "2026-11-25",
        "granularity" => "ALL",
        "shop_cipher" => "GCP_cipher"
      )
      expect(videos.first.dig("video", "play_url")).to eq("https://cdn.example.com/v/abc.mp4?sig=1")
    end

    it "rejects empty or non-numeric ids" do
      expect { adapter.fetch_shop_video_details(video_ids: [], date_from: Date.current, date_to: Date.current) }
        .to raise_error(ArgumentError)
      expect { adapter.fetch_shop_video_details(video_ids: [ "abc" ], date_from: Date.current, date_to: Date.current) }
        .to raise_error(ArgumentError)
    end
  end
end
