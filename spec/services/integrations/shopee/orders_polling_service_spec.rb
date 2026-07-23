require "rails_helper"

RSpec.describe Integrations::Shopee::OrdersPollingService do
  include ActiveSupport::Testing::TimeHelpers

  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let!(:channel) { tenant.channels.create!(name: "Shopee", platform: "shopee") }
  let(:credential) do
    tenant.channel_credentials.create!(
      channel: "shopee",
      status: "active",
      polling_enabled: true,
      credentials: {
        "partner_id" => "2011234",
        "partner_key" => "partner-secret",
        "shop_id" => "9001",
        "access_token" => "sp-access",
        "refresh_token" => "sp-refresh"
      }
    )
  end
  let(:adapter) { instance_double(Integrations::ShopeeAdapter) }
  let(:lock) { instance_double(Integrations::OrdersPollingLock, acquire: true, renew: true, release: true) }

  before do
    allow(Integrations::ShopeeAdapter).to receive(:new).and_return(adapter)
    allow(Integrations::OrdersPollingLock).to receive(:new).and_return(lock)
    allow(Integrations::Shopee::PendingEscrowSyncJob).to receive(:perform_later)
    allow(Integrations::Processors::ShopeeOrderProcessor).to receive(:call)
      .and_return(Integrations::EventProcessor::Result.new(outcome: :success, error_message: nil, metadata: {}))
  end

  after { travel_back }

  def order_detail(order_sn, create_time:, update_time: nil)
    {
      "order_sn" => order_sn,
      "order_status" => "READY_TO_SHIP",
      "create_time" => create_time.to_i,
      "update_time" => (update_time || create_time).to_i,
      "item_list" => []
    }
  end

  it "slices the 30-day backfill into <= 14-day get_order_list windows by create_time" do
    travel_to Time.zone.parse("2026-07-23 12:00:00 UTC")
    windows = []

    allow(adapter).to receive(:fetch_orders_page) do |time_range_field:, time_from:, time_to:, cursor:, page_size:|
      windows << [ time_range_field, time_from, time_to ]
      { "order_list" => [], "more" => false, "next_cursor" => "" }
    end

    result = described_class.call(credential, trigger: "manual")

    expect(result).to be_success
    expect(windows.size).to eq(3)
    expect(windows.map(&:first).uniq).to eq([ "create_time" ])
    windows.each do |_field, from, to|
      expect(to - from).to be <= 15.days.to_i
    end
    expect(windows.first[1]).to eq(30.days.ago.to_i)
    expect(windows.last[2]).to eq(Time.current.to_i)
  end

  it "paginates by cursor, fetches details in batch and advances the cursor to the latest create_time" do
    travel_to Time.zone.parse("2026-07-23 12:00:00 UTC")
    newest = Time.zone.parse("2026-07-22 10:00:00 UTC")

    pages = [
      { "order_list" => [ { "order_sn" => "SN-1" } ], "more" => true, "next_cursor" => "c2" },
      { "order_list" => [ { "order_sn" => "SN-2" } ], "more" => false, "next_cursor" => "" }
    ]
    cursors_seen = []
    call_count = 0
    allow(adapter).to receive(:fetch_orders_page) do |cursor:, **|
      cursors_seen << cursor
      page = pages[call_count] || { "order_list" => [], "more" => false, "next_cursor" => "" }
      call_count += 1
      page
    end
    allow(adapter).to receive(:fetch_order_details).with([ "SN-1" ])
      .and_return([ order_detail("SN-1", create_time: Time.zone.parse("2026-07-20 09:00:00 UTC")) ])
    allow(adapter).to receive(:fetch_order_details).with([ "SN-2" ])
      .and_return([ order_detail("SN-2", create_time: newest) ])

    result = described_class.call(credential, trigger: "manual")

    expect(result).to be_success
    expect(cursors_seen.first).to be_nil
    expect(cursors_seen).to include("c2")
    expect(Integrations::Processors::ShopeeOrderProcessor).to have_received(:call).twice
    expect(credential.reload.orders_sync_cursor_at.to_i).to eq(newest.to_i)
    expect(Integrations::Shopee::PendingEscrowSyncJob).to have_received(:perform_later).with(credential.id)
  end

  it "switches to update_time windows on incremental runs and keeps the cursor on empty results" do
    previous = Time.zone.parse("2026-07-22 18:00:00 UTC")
    credential.update!(orders_sync_cursor_at: previous)
    travel_to Time.zone.parse("2026-07-23 12:00:00 UTC")
    windows = []

    allow(adapter).to receive(:fetch_orders_page) do |time_range_field:, time_from:, time_to:, **|
      windows << [ time_range_field, time_from, time_to ]
      { "order_list" => [], "more" => false, "next_cursor" => "" }
    end

    result = described_class.call(credential, trigger: "scheduled")

    expect(result).to be_success
    expect(windows).to eq([ [ "update_time", (previous - 10.minutes).to_i, Time.current.to_i ] ])
    expect(credential.reload.orders_sync_cursor_at.to_i).to eq(previous.to_i)
  end

  it "skips duplicated order_sn inside one run without re-fetching details" do
    travel_to Time.zone.parse("2026-07-23 12:00:00 UTC")

    pages = [
      { "order_list" => [ { "order_sn" => "SN-1" }, { "order_sn" => "SN-1" } ], "more" => false, "next_cursor" => "" }
    ]
    call_count = 0
    allow(adapter).to receive(:fetch_orders_page) do |**|
      page = pages[call_count] || { "order_list" => [], "more" => false, "next_cursor" => "" }
      call_count += 1
      page
    end
    allow(adapter).to receive(:fetch_order_details).with([ "SN-1" ])
      .and_return([ order_detail("SN-1", create_time: Time.zone.parse("2026-07-22 09:00:00 UTC")) ])

    result = described_class.call(credential, trigger: "manual")

    expect(result).to be_success
    expect(adapter).to have_received(:fetch_order_details).once
    expect(Integrations::Processors::ShopeeOrderProcessor).to have_received(:call).once
    expect(result.metadata[:ignored_count]).to eq(1)
  end

  it "marks the credential as error on AuthenticationError" do
    travel_to Time.zone.parse("2026-07-23 12:00:00 UTC")
    allow(adapter).to receive(:fetch_orders_page)
      .and_raise(Integrations::AuthenticationError, "token rejeitado")

    result = described_class.call(credential, trigger: "scheduled")

    expect(result).to be_error
    expect(credential.reload.status).to eq("error")
  end

  it "returns rate_limited with retry_after so the job can re-enqueue" do
    travel_to Time.zone.parse("2026-07-23 12:00:00 UTC")
    allow(adapter).to receive(:fetch_orders_page)
      .and_raise(Integrations::RateLimitError.new("limite", retry_after: 90))

    result = described_class.call(credential, trigger: "scheduled")

    expect(result).to be_rate_limited
    expect(result.retry_after).to eq(90)
    expect(credential.reload.status).to eq("active")
  end

  it "skips when polling is disabled or the lock is taken" do
    credential.update!(polling_enabled: false)
    expect(described_class.call(credential).skipped?).to be(true)

    credential.update!(polling_enabled: true)
    allow(lock).to receive(:acquire).and_return(false)
    expect(described_class.call(credential).skipped?).to be(true)
  end
end
