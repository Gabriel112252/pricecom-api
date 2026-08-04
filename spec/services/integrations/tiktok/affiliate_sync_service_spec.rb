require "rails_helper"

RSpec.describe Integrations::Tiktok::AffiliateSyncService do
  let(:tenant) { Tenant.create!(name: "Loja Afiliados", slug: "afiliados-#{SecureRandom.hex(4)}") }
  let(:channel) { Channel.ensure_for!(tenant, "tiktok") }
  let(:credential) do
    tenant.channel_credentials.create!(
      channel: "tiktok",
      status: "active",
      credentials: { app_key: "key", app_secret: "secret", access_token: "token", shop_cipher: "cipher" }
    )
  end
  let(:adapter) { instance_double(Integrations::TiktokAdapter) }
  let(:lock) { instance_double(Integrations::Tiktok::AffiliateSyncLock, acquire: true, release: true, renew: true) }

  before do
    channel
    allow(Integrations::TiktokAdapter).to receive(:new).and_return(adapter)
    allow(Integrations::Tiktok::AffiliateSyncLock).to receive(:new).and_return(lock)
    allow_any_instance_of(described_class).to receive(:sleep)
  end

  def creator_payload(open_id, overrides = {})
    {
      "creator_open_id" => open_id,
      "username" => "user_#{open_id}",
      "nickname" => "Creator #{open_id}",
      "avatar" => { "url" => "https://example.com/#{open_id}.png" },
      "collaboration_status" => "NORMAL",
      "showcase_product_count" => 2,
      "content_product_count" => 1
    }.merge(overrides)
  end

  it "sends collaboration_status on every fetch_target_collaborations call — the bug that caused code 36009004 in production" do
    allow(adapter).to receive(:fetch_target_collaborations)
      .with(collaboration_status: "ONGOING", page_token: nil)
      .and_return({ "target_collaborations" => [], "next_page_token" => "" })

    described_class.call(credential)

    expect(adapter).to have_received(:fetch_target_collaborations).with(collaboration_status: "ONGOING", page_token: nil)
  end

  it "syncs creators from every target collaboration across pages and writes a daily snapshot" do
    allow(adapter).to receive(:fetch_target_collaborations)
      .with(collaboration_status: "ONGOING", page_token: nil)
      .and_return({ "target_collaborations" => [ { "id" => "tc-1" } ], "next_page_token" => "p2" })
    allow(adapter).to receive(:fetch_target_collaborations)
      .with(collaboration_status: "ONGOING", page_token: "p2")
      .and_return({ "target_collaborations" => [], "next_page_token" => "" })
    allow(adapter).to receive(:fetch_target_collaboration_detail).with(target_collaboration_id: "tc-1")
      .and_return({ "creators" => [ creator_payload("uABC"), creator_payload("uDEF") ] })

    result = described_class.call(credential)

    expect(result.success?).to eq(true)
    expect(AffiliateCreator.count).to eq(2)
    creator = AffiliateCreator.find_by(creator_open_id: "uABC")
    expect(creator.nickname).to eq("Creator uABC")
    expect(creator.target_collaboration_id).to eq("tc-1")

    snapshot = AffiliateDailySnapshot.find_by(tenant: tenant, channel: channel, snapshot_date: Date.current)
    expect(snapshot.total_creators_count).to eq(2)
    expect(snapshot.active_creators_count).to eq(2)
  end

  it "upserts an existing creator instead of duplicating it on a second run" do
    allow(adapter).to receive(:fetch_target_collaborations)
      .with(collaboration_status: "ONGOING", page_token: nil)
      .and_return({ "target_collaborations" => [ { "id" => "tc-1" } ], "next_page_token" => "" })
    allow(adapter).to receive(:fetch_target_collaboration_detail)
      .and_return({ "creators" => [ creator_payload("uABC", "showcase_product_count" => 1) ] })

    described_class.call(credential)
    allow(adapter).to receive(:fetch_target_collaboration_detail)
      .and_return({ "creators" => [ creator_payload("uABC", "showcase_product_count" => 5) ] })
    described_class.call(credential)

    expect(AffiliateCreator.count).to eq(1)
    expect(AffiliateCreator.find_by(creator_open_id: "uABC").showcase_product_count).to eq(5)
  end

  it "persists a checkpoint (including which status it was on) and re-raises on a rate limit, without marking the log finished" do
    allow(adapter).to receive(:fetch_target_collaborations)
      .with(collaboration_status: "ONGOING", page_token: nil)
      .and_raise(Integrations::RateLimitError.new("rate limited", retry_after: 20))

    expect { described_class.call(credential) }.to raise_error(Integrations::RateLimitError)

    log = IntegrationSyncLog.find_by(tenant: tenant, action: described_class::ACTION)
    expect(log.status).to eq("pending")
    expect(log.metadata["rate_limit_count"]).to eq(1)
    expect(log.metadata["status_index"]).to eq(0)
  end

  it "marks the credential as errored and finishes the log on an authentication error" do
    allow(adapter).to receive(:fetch_target_collaborations)
      .and_raise(Integrations::AuthenticationError, "token inválido")

    result = described_class.call(credential)

    expect(result.error?).to eq(true)
    expect(credential.reload.status).to eq("error")
    log = IntegrationSyncLog.find_by(tenant: tenant, action: described_class::ACTION)
    expect(log.status).to eq("error")
  end

  it "raises LockBusyError instead of running when another sync holds the lock" do
    allow(lock).to receive(:acquire).and_return(false)

    expect { described_class.call(credential) }.to raise_error(Integrations::Tiktok::AffiliateSyncLock::LockBusyError)
  end
end
