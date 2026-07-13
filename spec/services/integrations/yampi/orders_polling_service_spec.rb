require "rails_helper"

RSpec.describe Integrations::Yampi::OrdersPollingService do
  include ActiveSupport::Testing::TimeHelpers

  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let!(:channel) { tenant.channels.create!(name: "Yampi", platform: "yampi") }
  let(:credentials) { { alias: "loja", token: "token", secret_key: "secret", webhook_secret: "wh" } }
  let(:credential) do
    tenant.channel_credentials.create!(
      channel: "yampi",
      status: "active",
      polling_enabled: true,
      orders_sync_cursor_at: previous_cursor_at,
      credentials: credentials
    )
  end
  let(:previous_cursor_at) { nil }
  let(:adapter) { instance_double(Integrations::YampiAdapter) }
  let(:lock) { instance_double(Integrations::Yampi::PollingLock, acquire: true, renew: true, release: true) }
  let(:reservation) { Integrations::Yampi::RateLimiter::Reservation.new(allowed: true, count: 1, ttl_seconds: 60) }
  let(:rate_limiter) do
    instance_double(
      Integrations::Yampi::RateLimiter,
      reserve!: reservation,
      observe: nil,
      reserve_reached?: false,
      last_limit: nil,
      last_remaining: nil
    )
  end

  before do
    allow(Integrations::YampiAdapter).to receive(:new).and_return(adapter)
    allow(Integrations::Yampi::PollingLock).to receive(:new).and_return(lock)
    allow(Integrations::Yampi::RateLimiter).to receive(:new).and_return(rate_limiter)
    allow(Integrations::Processors::YampiOrderProcessor).to receive(:call)
      .and_return(Integrations::EventProcessor::Result.new(outcome: :success, error_message: nil, metadata: {}))
  end

  after { travel_back }

  it "advances a backfill cursor only to the latest order created_at returned by Yampi" do
    travel_to Time.zone.parse("2026-07-13 12:00:00 UTC")
    latest_order_at = Time.zone.parse("2026-07-11 18:30:00 UTC")
    orders = [
      raw_order(id: 1001, created_at: "2026-07-10 09:00:00"),
      raw_order(id: 1002, created_at: latest_order_at.iso8601)
    ]

    expect(adapter).to receive(:fetch_orders_page)
      .with(page: 1, date_filter: "created_at:2026-06-13|2026-07-13", limit: 100, skip_cache: true)
      .and_return(order_page(orders))

    result = described_class.call(credential, trigger: "manual")

    expect(result).to be_success
    expect(credential.reload.orders_sync_cursor_at.to_i).to eq(latest_order_at.to_i)
  end

  it "keeps the previous cursor when an incremental run receives no orders" do
    previous = Time.zone.parse("2026-07-11 18:30:00 UTC")
    credential.update!(orders_sync_cursor_at: previous)
    travel_to Time.zone.parse("2026-07-13 12:00:00 UTC")

    expect(adapter).to receive(:fetch_orders_page)
      .with(page: 1, date_filter: "created_at:2026-07-10|2026-07-13", limit: 100, skip_cache: true)
      .and_return(order_page([]))

    result = described_class.call(credential, trigger: "scheduled")

    expect(result).to be_success
    expect(credential.reload.orders_sync_cursor_at.to_i).to eq(previous.to_i)
  end

  it "does not move an incremental cursor backwards when the lookback only returns older orders" do
    previous = Time.zone.parse("2026-07-12 18:30:00 UTC")
    credential.update!(orders_sync_cursor_at: previous)
    travel_to Time.zone.parse("2026-07-13 12:00:00 UTC")

    expect(adapter).to receive(:fetch_orders_page)
      .with(page: 1, date_filter: "created_at:2026-07-10|2026-07-13", limit: 100, skip_cache: true)
      .and_return(order_page([ raw_order(id: 1003, created_at: "2026-07-11 10:00:00") ]))

    result = described_class.call(credential, trigger: "scheduled")

    expect(result).to be_success
    expect(credential.reload.orders_sync_cursor_at.to_i).to eq(previous.to_i)
  end

  def order_page(orders)
    Integrations::YampiAdapter::OrderPage.new(
      status: 200,
      body: {
        "data" => orders,
        "meta" => { "pagination" => { "current_page" => 1, "total_pages" => 1 } }
      },
      headers: {},
      duration_ms: 10,
      params: {}
    )
  end

  def raw_order(id:, created_at:)
    {
      "id" => id,
      "number" => id,
      "created_at" => created_at,
      "status" => { "data" => { "alias" => "paid" } },
      "value_total" => 100,
      "value_shipment" => 10,
      "value_discount" => 0,
      "items" => []
    }
  end
end
