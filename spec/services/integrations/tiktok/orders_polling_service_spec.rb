require "rails_helper"

RSpec.describe Integrations::Tiktok::OrdersPollingService do
  include ActiveSupport::Testing::TimeHelpers

  let(:tenant)   { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let!(:channel) { tenant.channels.create!(name: "TikTok Shop", platform: "tiktok") }
  let(:credentials) { { app_key: "key", app_secret: "secret", access_token: "token" } }
  let(:previous_cursor_at) { nil }
  let(:credential) do
    tenant.channel_credentials.create!(
      channel: "tiktok",
      status: "active",
      polling_enabled: true,
      orders_sync_cursor_at: previous_cursor_at,
      credentials: credentials
    )
  end
  let(:adapter) { instance_double(Integrations::TiktokAdapter) }
  let(:lock) { instance_double(Integrations::OrdersPollingLock, acquire: true, renew: true, release: true) }

  before do
    allow(Integrations::TiktokAdapter).to receive(:new).and_return(adapter)
    allow(Integrations::OrdersPollingLock).to receive(:new).and_return(lock)
    allow(Integrations::Processors::TiktokOrderProcessor).to receive(:call)
      .and_return(Integrations::EventProcessor::Result.new(outcome: :success, error_message: nil, metadata: {}))
  end

  after { travel_back }

  def raw_order(id:, create_time:)
    { "id" => id, "create_time" => create_time }
  end

  # Reproduces the 08/2026 production incident: a network error ("end of
  # file reached") mid-paginação used to lose ~1h25 of already-processed
  # progress because orders_sync_cursor_at was only persisted once, at the
  # very end of a successful #call. Now it's advanced after every page.
  it "persists the cursor incrementally after each page, so a crash mid-run doesn't lose progress already made" do
    travel_to Time.zone.parse("2026-08-13 12:00:00 UTC")

    page1_latest = Time.zone.parse("2026-08-01 10:00:00 UTC")
    page1 = {
      "orders" => [ raw_order(id: 1, create_time: page1_latest.to_i) ],
      "next_page_token" => "page-2"
    }

    call_count = 0
    allow(adapter).to receive(:fetch_orders_page) do
      call_count += 1
      call_count == 1 ? page1 : raise(EOFError, "end of file reached")
    end

    result = described_class.call(credential, trigger: "manual_recovery")

    expect(result).to be_error
    expect(result.error_message).to eq("end of file reached")
    expect(adapter).to have_received(:fetch_orders_page).twice
    # Page 1's progress survives the page 2 crash — cursor isn't left at
    # previous_cursor_at (nil here, the pre-run/backfill floor).
    expect(credential.reload.orders_sync_cursor_at.to_i).to eq(page1_latest.to_i)
  end

  it "raises LockLostError and stops fetching further pages when a mid-run renew fails" do
    travel_to Time.zone.parse("2026-08-13 12:00:00 UTC")

    order_at = Time.zone.parse("2026-08-01 10:00:00 UTC")
    page1 = {
      "orders" => [ raw_order(id: 1, create_time: order_at.to_i) ],
      "next_page_token" => "page-2"
    }
    allow(adapter).to receive(:fetch_orders_page).and_return(page1)
    allow(lock).to receive(:renew).and_return(false)

    result = described_class.call(credential, trigger: "manual_recovery")

    expect(result).to be_error
    expect(result.error_message).to include("lock perdido durante paginação (página 1)")
    # Never reaches page 2 — the loop raises right after the failed renew.
    expect(adapter).to have_received(:fetch_orders_page).once
    # Progress made before the lock was found lost is still kept.
    expect(credential.reload.orders_sync_cursor_at.to_i).to eq(order_at.to_i)

    log = tenant.integration_sync_logs.where(action: "tiktok_order_polling").order(:started_at).last
    expect(log.status).to eq("error")
    expect(log.error_message).to include("lock perdido")
  end
end
