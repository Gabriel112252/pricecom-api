require "rails_helper"

RSpec.describe Integrations::Tiktok::ShopAnalyticsSyncService do
  let(:tenant) { Tenant.create!(name: "Loja Analytics", slug: "analytics-#{SecureRandom.hex(4)}") }
  let(:channel) { Channel.ensure_for!(tenant, "tiktok") }
  let(:credential) do
    tenant.channel_credentials.create!(
      channel: "tiktok",
      status: "active",
      credentials: { app_key: "key", app_secret: "secret", access_token: "token", shop_cipher: "cipher" }
    )
  end
  let(:adapter) { instance_double(Integrations::TiktokAdapter) }

  before do
    channel
    allow(Integrations::TiktokAdapter).to receive(:new).and_return(adapter)
  end

  def analytics_payload(gmv_total: "1000.00", live: "600.00", video: "300.00", product_card: "100.00", refunds: "50.00")
    {
      "performance" => [
        {
          "intervals" => [
            {
              "start_date" => 30.days.ago.to_date.iso8601,
              "end_date" => Date.current.iso8601,
              "gmv" => { "amount" => gmv_total, "currency" => "BRL" },
              "gmv_breakdowns" => [
                { "amount" => live, "currency" => "BRL", "type" => "LIVE" },
                { "amount" => video, "currency" => "BRL", "type" => "VIDEO" },
                { "amount" => product_card, "currency" => "BRL", "type" => "PRODUCT_CARD" }
              ],
              "orders" => 42,
              "buyers" => 38,
              "product_impressions" => 5000,
              "product_page_views" => 1200,
              "refunds" => { "amount" => refunds, "currency" => "BRL" },
              "cancellations_and_returns" => 3
            }
          ]
        }
      ],
      "latest_available_date" => Date.current.iso8601
    }
  end

  it "persists a snapshot with the GMV split by content type and the funnel counters" do
    allow(adapter).to receive(:fetch_shop_analytics).and_return(analytics_payload)

    result = described_class.call(credential, trigger: "spec")

    expect(result.success?).to eq(true)
    snapshot = tenant.shop_analytics_snapshots.sole
    expect(snapshot.channel).to eq(channel)
    expect(snapshot.gmv_total).to eq(BigDecimal("1000.00"))
    expect(snapshot.gmv_live).to eq(BigDecimal("600.00"))
    expect(snapshot.gmv_video).to eq(BigDecimal("300.00"))
    expect(snapshot.gmv_product_card).to eq(BigDecimal("100.00"))
    expect(snapshot.refunds_amount).to eq(BigDecimal("50.00"))
    expect(snapshot.orders).to eq(42)
    expect(snapshot.buyers).to eq(38)
    expect(snapshot.product_impressions).to eq(5000)
    expect(snapshot.product_page_views).to eq(1200)
    expect(snapshot.cancellations_and_returns).to eq(3)
    expect(snapshot.period_start).to eq(30.days.ago.to_date)
    expect(snapshot.period_end).to eq(Date.current)
    expect(snapshot.synced_at).to be_present
    expect(snapshot.raw_response).to eq(analytics_payload)
  end

  it "requests the default 30-day window with granularity ALL" do
    allow(adapter).to receive(:fetch_shop_analytics).and_return(analytics_payload)

    described_class.call(credential, trigger: "spec")

    expect(adapter).to have_received(:fetch_shop_analytics).with(
      date_from: 30.days.ago.to_date, date_to: Date.current, granularity: "ALL"
    )
  end

  it "updates the existing snapshot for the same period instead of duplicating it" do
    allow(adapter).to receive(:fetch_shop_analytics).and_return(analytics_payload)
    described_class.call(credential, trigger: "spec")

    allow(adapter).to receive(:fetch_shop_analytics).and_return(analytics_payload(gmv_total: "2000.00"))
    described_class.call(credential, trigger: "spec")

    expect(tenant.shop_analytics_snapshots.count).to eq(1)
    expect(tenant.shop_analytics_snapshots.sole.gmv_total).to eq(BigDecimal("2000.00"))
  end

  it "defaults an unrecognized/missing breakdown type to zero without dropping it from gmv_total" do
    payload = analytics_payload
    payload["performance"][0]["intervals"][0]["gmv_breakdowns"] = [
      { "amount" => "700.00", "currency" => "BRL", "type" => "SOME_NEW_TYPE" }
    ]
    allow(adapter).to receive(:fetch_shop_analytics).and_return(payload)

    described_class.call(credential, trigger: "spec")

    snapshot = tenant.shop_analytics_snapshots.sole
    expect(snapshot.gmv_live).to eq(BigDecimal("0"))
    expect(snapshot.gmv_video).to eq(BigDecimal("0"))
    expect(snapshot.gmv_product_card).to eq(BigDecimal("0"))
    expect(snapshot.gmv_total).to eq(BigDecimal("1000.00"))
  end

  it "handles an empty performance array without raising, persisting zeros" do
    allow(adapter).to receive(:fetch_shop_analytics).and_return({ "performance" => [] })

    result = described_class.call(credential, trigger: "spec")

    expect(result.success?).to eq(true)
    snapshot = tenant.shop_analytics_snapshots.sole
    expect(snapshot.gmv_total).to eq(BigDecimal("0"))
    expect(snapshot.orders).to eq(0)
  end

  it "marks the credential as error and does not raise on an authentication failure" do
    allow(adapter).to receive(:fetch_shop_analytics).and_raise(Integrations::AuthenticationError, "escopo de analytics ausente")

    result = described_class.call(credential, trigger: "spec")

    expect(result.error?).to eq(true)
    expect(credential.reload.status).to eq("error")
    expect(ShopAnalyticsSnapshot.count).to eq(0)
  end

  it "re-raises RateLimitError so the job can back off and retry" do
    allow(adapter).to receive(:fetch_shop_analytics).and_raise(Integrations::RateLimitError.new("too many requests", retry_after: 5))

    expect { described_class.call(credential, trigger: "spec") }.to raise_error(Integrations::RateLimitError)

    log = tenant.integration_sync_logs.find_by!(action: "tiktok_shop_analytics_sync")
    expect(log.status).to eq("error")
  end

  it "skips when the tenant has no tiktok channel" do
    tenant_without_channel = Tenant.create!(name: "Sem Canal", slug: "sem-canal-#{SecureRandom.hex(4)}")
    credential_without_channel = tenant_without_channel.channel_credentials.create!(
      channel: "tiktok", status: "active",
      credentials: { app_key: "key", app_secret: "secret", access_token: "token", shop_cipher: "cipher" }
    )

    result = described_class.call(credential_without_channel, trigger: "spec")

    expect(result.skipped?).to eq(true)
  end
end
