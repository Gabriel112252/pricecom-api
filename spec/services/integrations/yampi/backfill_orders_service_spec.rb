require "rails_helper"

RSpec.describe Integrations::Yampi::BackfillOrdersService do
  let(:tenant)  { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:channel) { tenant.channels.create!(name: "Yampi", platform: "yampi") }
  let(:channel_credential) do
    tenant.channel_credentials.create!(
      channel: "yampi", status: "active",
      credentials: { alias: "loja", token: "tok", secret_key: "sec", webhook_secret: "wh" }
    )
  end
  let(:orders_url)     { "https://api.dooki.com.br/v2/loja/orders" }
  let(:orders_fixture) { File.read(Rails.root.join("spec/fixtures/integrations/yampi_orders.json")) }

  def stub_orders(body: orders_fixture, status: 200)
    stub_request(:get, "https://api.dooki.com.br/v2/loja/catalog/products")
      .with(query: hash_including("page" => "1", "per_page" => "1"))
      .to_return(status: 200, body: { data: [] }.to_json, headers: { "Content-Type" => "application/json" })
    stub_request(:get, orders_url)
      .with(query: hash_including("page" => "1"))
      .to_return(status: status, body: body, headers: { "Content-Type" => "application/json" })
  end

  before { channel } # make sure the Channel(platform: "yampi") exists before UpsertOrder needs it

  describe "a successful backfill" do
    before { stub_orders }

    it "creates one Order per raw order returned, with correctly-parsed fields" do
      result = described_class.call(channel_credential, days: 30)

      expect(result.success?).to eq(true)
      expect(result.created_count).to eq(2)
      expect(result.updated_count).to eq(0)
      expect(result.skipped).to be_empty

      order = tenant.orders.find_by(external_id: "1000001")
      expect(order.gross_value).to eq(BigDecimal("199.90"))
      expect(order.state).to eq("SP")
      expect(order.order_items.sole.sku).to eq("CAM-001-P-AZUL")
    end

    it "logs the run to IntegrationSyncLog with created/updated/skipped counts" do
      described_class.call(channel_credential, days: 30)

      log = IntegrationSyncLog.where(tenant: tenant, action: "order_backfill").last
      expect(log.status).to eq("success")
      expect(log.metadata["created_count"]).to eq(2)
      expect(log.metadata["updated_count"]).to eq(0)
      expect(log.metadata["days"]).to eq(30)
    end

    it "deducts stock the same way the webhook would, and sets stock_deducted_at" do
      described_class.call(channel_credential, days: 30)

      order = tenant.orders.find_by(external_id: "1000001")
      expect(order.stock_deducted_at).to be_present
    end
  end

  describe "running the backfill twice (idempotency)" do
    before { stub_orders }

    it "updates the existing orders on the second run instead of duplicating them" do
      described_class.call(channel_credential, days: 30)
      expect(tenant.orders.count).to eq(2)

      result = described_class.call(channel_credential, days: 30)

      expect(tenant.orders.count).to eq(2) # still 2, nothing duplicated
      expect(result.created_count).to eq(0)
      expect(result.updated_count).to eq(2)
    end

    it "does not re-deduct stock for an order the webhook already processed" do
      # Simulate the webhook having already ingested this order before the backfill runs.
      order = tenant.orders.create!(
        external_id: "1000001", channel: channel, order_number: "555001",
        ordered_at: Time.current, stock_deducted_at: 1.hour.ago
      )
      original_timestamp = order.stock_deducted_at

      described_class.call(channel_credential, days: 30)

      expect(order.reload.stock_deducted_at).to be_within(1.second).of(original_timestamp)
    end
  end

  describe "a duplicate external_id within the same run (pagination overlap)" do
    it "processes it once and counts the repeat as skipped" do
      duplicated = JSON.parse(orders_fixture)
      duplicated["data"] << duplicated["data"].first.merge("number" => 999999)
      stub_orders(body: duplicated.to_json)

      result = described_class.call(channel_credential, days: 30)

      expect(result.created_count).to eq(2)
      expect(result.skipped.size).to eq(1)
      expect(result.skipped.first[:reason]).to eq("duplicado na mesma importação")
    end
  end

  describe "authentication failure" do
    it "marks the credential as errored and returns an error result" do
      stub_request(:get, "https://api.dooki.com.br/v2/loja/catalog/products")
        .with(query: hash_including("page" => "1"))
        .to_return(status: 401, body: { message: "Unauthenticated" }.to_json)

      result = described_class.call(channel_credential, days: 30)

      expect(result.error?).to eq(true)
      expect(channel_credential.reload.status).to eq("error")
    end
  end

  describe "days param" do
    it "defaults to 30 when not given" do
      stub_orders
      expect(Integrations::YampiAdapter).to receive(:new).and_wrap_original do |method, *args|
        method.call(*args)
      end

      result = described_class.call(channel_credential, days: nil)
      expect(result.success?).to eq(true) # falls back to DEFAULT_DAYS instead of erroring on nil
    end
  end
end
