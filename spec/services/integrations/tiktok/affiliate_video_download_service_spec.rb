require "rails_helper"

RSpec.describe Integrations::Tiktok::AffiliateVideoDownloadService do
  let(:tenant) { Tenant.create!(name: "Loja Download", slug: "download-#{SecureRandom.hex(4)}") }
  let(:channel) { Channel.ensure_for!(tenant, "tiktok") }
  let(:credential) do
    tenant.channel_credentials.create!(
      channel: "tiktok",
      status: "active",
      credentials: { app_key: "key", app_secret: "secret", access_token: "token", shop_cipher: "cipher" }
    )
  end
  let(:adapter) { instance_double(Integrations::TiktokAdapter) }
  let(:video) do
    channel.affiliate_videos.create!(
      tenant: tenant, channel_credential: credential, video_id: "7300000000000000001",
      username: "criadora_a", download_status: "queued"
    )
  end
  let(:play_url) { "https://cdn.example.com/v/abc.mp4?sig=1" }
  let(:video_bytes) { "\x00\x00\x00\x18ftypmp42fake-video-bytes".b }

  before do
    allow(Integrations::TiktokAdapter).to receive(:new).and_return(adapter)
  end

  def details_entry(overrides = {})
    {
      "video_id" => video.video_id,
      "video" => {
        "id" => video.video_id,
        "play_url" => play_url,
        "thumbnail_url" => "https://cdn.example.com/t/abc.jpg",
        "duration" => 34,
        "title" => "Meu skincare"
      }
    }.merge(overrides)
  end

  it "downloads from TikTok's play_url and attaches the file" do
    allow(adapter).to receive(:fetch_shop_video_details).and_return([ details_entry ])
    stub_request(:get, play_url).to_return(status: 200, body: video_bytes, headers: { "Content-Type" => "video/mp4" })

    result = described_class.call(video)

    expect(result.success?).to eq(true)
    expect(result.source).to eq("play_url")
    video.reload
    expect(video.download_status).to eq("downloaded")
    expect(video.downloaded_at).to be_present
    expect(video.file).to be_attached
    expect(video.file.download).to eq(video_bytes)
    expect(video.file.filename.to_s).to eq("criadora_a-7300000000000000001.mp4")
    expect(video.thumbnail_url).to eq("https://cdn.example.com/t/abc.jpg")
    expect(adapter).to have_received(:fetch_shop_video_details)
      .with(video_ids: [ "7300000000000000001" ], date_from: Date.current - 29, date_to: Date.current)
  end

  it "asks for the details in the window the sync last saw the video in" do
    video.update!(metrics: { "window" => { "from" => (Date.current - 59).iso8601, "to" => (Date.current - 30).iso8601 } })
    allow(adapter).to receive(:fetch_shop_video_details).and_return([ details_entry ])
    stub_request(:get, play_url).to_return(status: 200, body: video_bytes, headers: { "Content-Type" => "video/mp4" })

    described_class.call(video)

    expect(adapter).to have_received(:fetch_shop_video_details)
      .with(video_ids: [ "7300000000000000001" ], date_from: Date.current - 59, date_to: Date.current - 30)
  end

  it "follows a redirect from the play_url" do
    allow(adapter).to receive(:fetch_shop_video_details).and_return([ details_entry ])
    stub_request(:get, play_url).to_return(status: 302, headers: { "Location" => "https://cdn2.example.com/final.mp4" })
    stub_request(:get, "https://cdn2.example.com/final.mp4")
      .to_return(status: 200, body: video_bytes, headers: { "Content-Type" => "application/octet-stream" })

    result = described_class.call(video)

    expect(result.success?).to eq(true)
    expect(video.reload.file.content_type).to eq("video/mp4")
  end

  it "falls back to yt-dlp on the public TikTok link when the API has no play_url" do
    allow(adapter).to receive(:fetch_shop_video_details)
      .and_return([ { "video_id" => video.video_id, "error" => { "code" => "300001", "message" => "Invalid video ID." } } ])
    allow(Testimonials::TiktokVideoDownloader).to receive(:call)
      .with("https://www.tiktok.com/@criadora_a/video/7300000000000000001")
      .and_return({ success: true, bytes: video_bytes, content_type: "video/mp4" })

    result = described_class.call(video)

    expect(result.success?).to eq(true)
    expect(result.source).to eq("yt_dlp")
    expect(video.reload.file).to be_attached
  end

  it "marks the video failed with both reasons when every source fails" do
    allow(adapter).to receive(:fetch_shop_video_details).and_return([ details_entry ])
    stub_request(:get, play_url).to_return(status: 403, body: "forbidden")
    allow(Testimonials::TiktokVideoDownloader).to receive(:call)
      .and_return({ success: false, error: "não foi possível baixar o vídeo do TikTok" })

    result = described_class.call(video)

    expect(result.error?).to eq(true)
    video.reload
    expect(video.download_status).to eq("failed")
    expect(video.download_error).to include("HTTP 403").and include("yt-dlp")
    expect(video.file).not_to be_attached
  end

  it "puts the video back to pending and re-raises on a rate limit" do
    allow(adapter).to receive(:fetch_shop_video_details)
      .and_raise(Integrations::RateLimitError.new("slow down", retry_after: 10))

    expect { described_class.call(video) }.to raise_error(Integrations::RateLimitError)
    expect(video.reload.download_status).to eq("pending")
  end

  it "does nothing for a video that already has its file" do
    video.file.attach(io: StringIO.new(video_bytes), filename: "x.mp4", content_type: "video/mp4")
    video.update!(download_status: "downloaded")
    allow(adapter).to receive(:fetch_shop_video_details)

    result = described_class.call(video)

    expect(result.skipped?).to eq(true)
    expect(adapter).not_to have_received(:fetch_shop_video_details)
  end
end
