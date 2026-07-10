require "rails_helper"

RSpec.describe Financials::PagarmeSyncService do
  let(:tenant)  { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:channel) { tenant.channels.create!(name: "Yampi", platform: "yampi") }
  let(:financial_source) do
    tenant.financial_sources.create!(
      provider: "pagarme", name: "Pagar.me", source_type: "gateway", status: "active",
      credentials: { api_key: "sk_test_abc123" }
    )
  end
  let(:orders_fixture) { File.read(Rails.root.join("spec/fixtures/integrations/pagarme_orders.json")) }
  let!(:order) do
    tenant.orders.create!(
      channel: channel, external_id: "555001", order_number: "YAMPI-555001",
      ordered_at: Time.current, gross_value: 199.90, order_type: "sale"
    )
  end

  def stub_orders(body: orders_fixture)
    stub_request(:get, "https://api.pagar.me/core/v5/orders")
      .with(query: hash_including("page" => "1"))
      .to_return(status: 200, body: body, headers: { "Content-Type" => "application/json" })
  end

  describe "a successful sync" do
    before { stub_orders }

    it "creates a FinancialSettlementItem per PAID charge, matched to the existing order" do
      result = described_class.call(financial_source, days: 30)

      expect(result.success?).to eq(true)
      expect(result.created_count).to eq(1) # only the paid charge — the failed one is skipped
      expect(result.skipped.size).to eq(1)

      item = FinancialSettlementItem.find_by(external_id: "ch_gmnW101c9YTvQVLB")
      expect(item.external_order_id).to eq("YAMPI-555001")
      expect(item.gross_amount).to eq(BigDecimal("199.90"))
      expect(item.order).to eq(order)
      expect(item.status).to eq("matched") # via the reused Financials::MatchSettlementItem
    end

    it "skips a non-paid transaction with a clear reason instead of treating it as reconciled" do
      result = described_class.call(financial_source, days: 30)

      skipped = result.skipped.find { |s| s[:external_id] == "ch_nM5PkjcyLUa6Nr1w" }
      expect(skipped[:reason]).to include("failed")
    end

    it "logs the run to IntegrationSyncLog" do
      described_class.call(financial_source, days: 30)

      log = IntegrationSyncLog.where(tenant: tenant, action: "pagarme_settlement_sync").last
      expect(log.status).to eq("success")
      expect(log.metadata["created_count"]).to eq(1)
    end
  end

  describe "running the sync twice for an overlapping window (idempotency)" do
    before { stub_orders }

    it "updates the existing item instead of duplicating it" do
      described_class.call(financial_source, days: 30)
      expect(FinancialSettlementItem.where(tenant: tenant).count).to eq(1)

      result = described_class.call(financial_source, days: 30)

      expect(FinancialSettlementItem.where(tenant: tenant).count).to eq(1)
      expect(result.created_count).to eq(0)
      expect(result.updated_count).to eq(1)
    end
  end

  describe "authentication failure" do
    it "marks the financial source as errored" do
      stub_request(:get, "https://api.pagar.me/core/v5/orders")
        .with(query: hash_including("page" => "1"))
        .to_return(status: 401, body: { message: "Unauthorized" }.to_json)

      result = described_class.call(financial_source, days: 30)

      expect(result.error?).to eq(true)
      expect(financial_source.reload.status).to eq("error")
    end
  end
end
