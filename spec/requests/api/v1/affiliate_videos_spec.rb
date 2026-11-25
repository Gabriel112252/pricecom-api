require "rails_helper"

RSpec.describe "Affiliate videos", type: :request do
  let(:tenant)   { Tenant.create!(name: "Loja Vídeos", slug: "videos-api-#{SecureRandom.hex(4)}") }
  let(:operador) { tenant.users.create!(name: "Operador", email: "op@#{SecureRandom.hex(4)}.com", password: "password123", role: "operador") }
  let(:channel)  { Channel.ensure_for!(tenant, "tiktok") }
  let(:other_tenant) { Tenant.create!(name: "Outra", slug: "outra-#{SecureRandom.hex(4)}") }
  let(:video_bytes) { "\x00\x00\x00\x18ftypmp42fake-video-bytes".b }

  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    example.run
    ActiveJob::Base.queue_adapter = original_adapter
  end

  def auth_headers(user)
    { "Authorization" => "Bearer #{JsonWebToken.encode(user_id: user.id)}" }
  end

  def create_video(video_id, attrs = {})
    channel.affiliate_videos.create!({ tenant: tenant, video_id: video_id, username: "criadora_a", nickname: "Criadora A" }.merge(attrs))
  end

  def downloaded_video(video_id, attrs = {})
    video = create_video(video_id, attrs)
    video.file.attach(io: StringIO.new(video_bytes), filename: "criadora_a-#{video_id}.mp4", content_type: "video/mp4")
    video.update!(download_status: "downloaded")
    video
  end

  def other_tenant_video
    Channel.ensure_for!(other_tenant, "tiktok").affiliate_videos.create!(tenant: other_tenant, video_id: "99")
  end

  def enqueued_downloads
    ActiveJob::Base.queue_adapter.enqueued_jobs.select { |job| job[:job] == Integrations::Tiktok::AffiliateVideoDownloadJob }
  end

  describe "GET /api/v1/affiliate_videos" do
    it "lists the tenant's videos top GMV first, with the TikTok link and, once downloaded, the file link" do
      downloaded_video("1", metrics: { "gmv" => { "amount" => "900.00", "currency" => "BRL" }, "views" => 50 })
      create_video("2", metrics: { "gmv" => { "amount" => "2500.00", "currency" => "BRL" } })
      other_tenant_video

      get "/api/v1/affiliate_videos", params: { ordem: "gmv", per_page: 10 }, headers: auth_headers(operador)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["rows"].map { |row| row["video_id"] }).to eq(%w[2 1])
      expect(body["meta"]).to include("total_count" => 2, "current_page" => 1, "per_page" => 10)
      top, downloaded = body["rows"]
      expect(top).to include("gmv" => "2500.00", "download_status" => "pending", "tiktok_url" => "https://www.tiktok.com/@criadora_a/video/2")
      expect(top["download_url"]).to be_nil
      expect(downloaded).to include("download_status" => "downloaded", "views" => 50)
      expect(downloaded["download_url"]).to include("/rails/active_storage/blobs/redirect/")
    end

    it "filters by creator and rejects an unknown order or a bad date" do
      create_video("1")
      create_video("2", username: "outra", nickname: "Outra")

      get "/api/v1/affiliate_videos", params: { criadora: "@Outra" }, headers: auth_headers(operador)
      expect(JSON.parse(response.body)["rows"].map { |row| row["video_id"] }).to eq(%w[2])

      get "/api/v1/affiliate_videos", params: { ordem: "aleatorio" }, headers: auth_headers(operador)
      expect(response).to have_http_status(:unprocessable_entity)

      get "/api/v1/affiliate_videos", params: { from: "2026-13-45" }, headers: auth_headers(operador)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "requires authentication" do
      get "/api/v1/affiliate_videos"

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET /api/v1/affiliate_videos/:id" do
    it "shows the download status and the failure reason" do
      video = create_video("1", download_status: "failed", download_error: "HTTP 403")

      get "/api/v1/affiliate_videos/#{video.id}", headers: auth_headers(operador)

      expect(JSON.parse(response.body)).to include("download_status" => "failed", "download_error" => "HTTP 403", "download_url" => nil)
    end
  end

  describe "POST /api/v1/affiliate_videos/:id/download" do
    it "queues the download of a video without a file, only once" do
      video = create_video("1")

      post "/api/v1/affiliate_videos/#{video.id}/download", headers: auth_headers(operador)
      expect(JSON.parse(response.body)).to include("download_status" => "queued")
      expect(video.reload.download_status).to eq("queued")

      post "/api/v1/affiliate_videos/#{video.id}/download", headers: auth_headers(operador)
      expect(JSON.parse(response.body)).to include("download_status" => "in_progress")

      expect(enqueued_downloads.map { |job| job[:args] }).to eq([ [ video.id ] ])
    end

    it "returns the file link of a downloaded video" do
      video = downloaded_video("1")

      post "/api/v1/affiliate_videos/#{video.id}/download", headers: auth_headers(operador)

      body = JSON.parse(response.body)
      expect(body["download_status"]).to eq("downloaded")
      expect(body["download_url"]).to include("/rails/active_storage/blobs/redirect/")
    end

    it "never touches another tenant's video" do
      post "/api/v1/affiliate_videos/#{other_tenant_video.id}/download", headers: auth_headers(operador)

      expect(response).to have_http_status(:not_found)
      expect(enqueued_downloads).to be_empty
    end
  end
end
