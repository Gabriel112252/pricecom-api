require "rails_helper"

RSpec.describe Integrations::Tiktok::AffiliateVideoSyncService do
  let(:tenant) { Tenant.create!(name: "Loja Vídeos", slug: "videos-#{SecureRandom.hex(4)}") }
  let(:channel) { Channel.ensure_for!(tenant, "tiktok") }
  let(:credential) do
    tenant.channel_credentials.create!(
      channel: "tiktok",
      status: "active",
      credentials: { app_key: "key", app_secret: "secret", access_token: "token", shop_cipher: "cipher" }
    )
  end
  let(:adapter) { instance_double(Integrations::TiktokAdapter) }
  let(:today) { Date.new(2026, 11, 25) }
  let!(:target_creator) do
    channel.affiliate_creators.create!(
      tenant: tenant, creator_open_id: "uTARGET", username: "Criadora_A", nickname: "Criadora A", target_collaboration_id: "tc-1"
    )
  end

  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    example.run
    ActiveJob::Base.queue_adapter = original_adapter
  end

  before do
    allow(Integrations::TiktokAdapter).to receive(:new).and_return(adapter)
  end

  def video_payload(id, open_id:, user_name:, overrides: {})
    {
      "id" => id,
      "title" => "Vídeo #{id}",
      "username" => user_name,
      "duration" => 30,
      "video_post_time" => "2026-11-20 10:00:00",
      "creator" => { "author_type" => "AFFILIATE", "open_id" => open_id, "user_name" => user_name, "nick_name" => "Nick #{id}" },
      "products" => [ { "id" => "p1", "name" => "Sérum" } ],
      "views" => 1000,
      "likes" => 50,
      "gmv" => { "amount" => "120.00", "currency" => "BRL" }
    }.merge(overrides)
  end

  def stub_window(from, to, pages)
    pages.each_with_index do |videos, index|
      token_in = index.zero? ? nil : "p#{index}"
      token_out = index == pages.size - 1 ? "" : "p#{index + 1}"
      allow(adapter).to receive(:fetch_shop_videos)
        .with(date_from: from, date_to: to, account_type: "AFFILIATE_ACCOUNTS", page_token: token_in)
        .and_return({ "videos" => videos, "next_page_token" => token_out })
    end
  end

  it "keeps only videos from target-collaboration creators, across pages, and queues their downloads" do
    stub_window(today - 59, today, [
      [ video_payload("111", open_id: "uTARGET", user_name: "criadora_a"), video_payload("222", open_id: "uOTHER", user_name: "outra") ],
      [ video_payload("333", open_id: "uTARGET", user_name: "criadora_a") ]
    ])

    result = described_class.call(credential, days_back: 60, today: today, auto_download: true)

    expect(result.success?).to eq(true)
    expect(AffiliateVideo.pluck(:video_id)).to contain_exactly("111", "333")
    video = AffiliateVideo.find_by(video_id: "111")
    expect(video.affiliate_creator).to eq(target_creator)
    expect(video.channel_credential).to eq(credential)
    expect(video.username).to eq("criadora_a")
    expect(video.products).to eq([ { "id" => "p1", "name" => "Sérum" } ])
    expect(video.metrics).to include("views" => 1000, "gmv" => { "amount" => "120.00", "currency" => "BRL" })
    expect(video.posted_at).to eq(Time.zone.parse("2026-11-20 10:00:00"))
    expect(video.download_status).to eq("queued")

    enqueued = ActiveJob::Base.queue_adapter.enqueued_jobs.map { |job| job[:job] }
    expect(enqueued).to eq([ Integrations::Tiktok::AffiliateVideoDownloadJob ] * 2)

    log = IntegrationSyncLog.find_by(action: described_class::ACTION)
    expect(log.status).to eq("success")
    expect(log.metadata).to include("videos_created" => 2, "pages" => 2)
  end

  it "matches a creator by username when the open_id differs" do
    stub_window(today - 59, today, [ [ video_payload("444", open_id: "uDIFFERENT", user_name: "criadora_a") ] ])

    described_class.call(credential, days_back: 60, today: today, auto_download: false)

    expect(AffiliateVideo.find_by(video_id: "444").affiliate_creator).to eq(target_creator)
  end

  it "walks days_back in 60-day windows, newest first, keeping the newest window's metrics" do
    stub_window(today - 59, today, [ [ video_payload("555", open_id: "uTARGET", user_name: "criadora_a", overrides: { "views" => 10 }) ] ])
    stub_window(today - 89, today - 60, [ [ video_payload("555", open_id: "uTARGET", user_name: "criadora_a", overrides: { "views" => 999 }) ] ])

    described_class.call(credential, days_back: 90, today: today, auto_download: false)

    video = AffiliateVideo.find_by(video_id: "555")
    expect(video.metrics["views"]).to eq(10)
    expect(video.metrics["window"]).to eq("from" => (today - 59).iso8601, "to" => today.iso8601)
    expect(adapter).to have_received(:fetch_shop_videos).twice
  end

  it "updates an existing video instead of duplicating it and doesn't re-queue a downloaded one" do
    existing = channel.affiliate_videos.create!(tenant: tenant, video_id: "111", download_status: "downloaded")
    stub_window(today - 59, today, [ [ video_payload("111", open_id: "uTARGET", user_name: "criadora_a", overrides: { "views" => 7 }) ] ])

    described_class.call(credential, days_back: 60, today: today, auto_download: true)

    expect(AffiliateVideo.count).to eq(1)
    expect(existing.reload.metrics["views"]).to eq(7)
    expect(existing.download_status).to eq("downloaded")
    expect(ActiveJob::Base.queue_adapter.enqueued_jobs).to be_empty
  end

  it "skips without calling TikTok when no target-collaboration creator was synced yet" do
    target_creator.update!(target_collaboration_id: nil)
    allow(adapter).to receive(:fetch_shop_videos)

    result = described_class.call(credential, days_back: 60, today: today)

    expect(result.skipped?).to eq(true)
    expect(adapter).not_to have_received(:fetch_shop_videos)
    expect(IntegrationSyncLog.where(action: described_class::ACTION)).to be_empty
  end

  it "records a missing analytics scope as an error without disabling the credential" do
    allow(adapter).to receive(:fetch_shop_videos).and_raise(Integrations::AuthenticationError, "sem permissão/escopo")

    result = described_class.call(credential, days_back: 60, today: today)

    expect(result.error?).to eq(true)
    expect(credential.reload.status).to eq("active")
    expect(IntegrationSyncLog.find_by(action: described_class::ACTION).status).to eq("error")
  end

  it "re-raises a rate limit after closing the log" do
    allow(adapter).to receive(:fetch_shop_videos).and_raise(Integrations::RateLimitError.new("slow down", retry_after: 30))

    expect { described_class.call(credential, days_back: 60, today: today) }.to raise_error(Integrations::RateLimitError)
    expect(IntegrationSyncLog.find_by(action: described_class::ACTION).status).to eq("error")
  end
end
