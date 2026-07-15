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
  let!(:order) do
    tenant.orders.create!(
      channel: channel, external_id: "YAMPI-555001", order_number: "555001",
      ordered_at: Time.current, gross_value: 199.90, order_type: "sale"
    )
  end
  let!(:legacy_settlement) do
    financial_source.financial_settlements.create!(
      tenant: tenant,
      channel: channel,
      external_id: "legacy-charges",
      period_start: Date.current,
      period_end: Date.current,
      status: "paid"
    )
  end
  let!(:legacy_item) do
    legacy_settlement.financial_settlement_items.create!(
      tenant: tenant,
      order: order,
      external_id: "ch_gmnW101c9YTvQVLB",
      external_order_id: order.external_id,
      transaction_type: "sale",
      gross_amount: 199.90,
      net_amount: 199.90,
      status: "matched"
    )
  end
  let(:payables_fixture) do
    {
      data: [
        {
          id: "pay_gmnW101c9YTvQVLB",
          status: "paid",
          amount: 19990,
          fee: 1000,
          anticipation_fee: 550,
          installment: 1,
          transaction_id: "tran_1",
          charge_id: "ch_gmnW101c9YTvQVLB",
          recipient_id: "rp_1",
          payment_date: "2026-07-20",
          original_payment_date: "2026-07-20",
          payment_method: "credit_card",
          accrual_date: "2026-07-10T12:00:00Z",
          date_created: "2026-07-10T12:00:01Z"
        }
      ],
      paging: { forward_cursor: nil }
    }.to_json
  end

  def stub_payables(body: payables_fixture)
    stub_request(:get, "https://api.pagar.me/core/v5/payables")
      .with(query: hash_including("payment_date_since" => "2026-06-15"))
      .to_return(status: 200, body: body, headers: { "Content-Type" => "application/json" })
  end

  describe "a successful sync" do
    before do
      travel_to Time.zone.parse("2026-07-15T12:00:00Z")
      stub_payables
    end

    after { travel_back }

    it "creates a FinancialReceivable and settlement item from a Pagar.me payable" do
      result = described_class.call(financial_source, days: 30)

      expect(result.success?).to eq(true)
      expect(result.created_count).to eq(1)
      expect(result.skipped.size).to eq(0)

      receivable = FinancialReceivable.find_by(payable_id: "pay_gmnW101c9YTvQVLB")
      item = receivable.financial_settlement_item
      expect(receivable.order).to eq(order)
      expect(item.external_order_id).to eq("YAMPI-555001")
      expect(item.gross_amount).to eq(BigDecimal("199.90"))
      expect(item.order).to eq(order)
      expect(item.fee_amount).to eq(BigDecimal("15.5"))
    end

    it "logs the run to IntegrationSyncLog" do
      described_class.call(financial_source, days: 30)

      log = IntegrationSyncLog.where(tenant: tenant, action: "pagarme_payable_sync").last
      expect(log.status).to eq("success")
      expect(log.metadata["created_count"]).to eq(1)
    end
  end

  describe "running the sync twice for an overlapping window (idempotency)" do
    before do
      travel_to Time.zone.parse("2026-07-15T12:00:00Z")
      stub_payables
    end

    after { travel_back }

    it "updates the existing item instead of duplicating it" do
      described_class.call(financial_source, days: 30)
      expect(FinancialReceivable.where(tenant: tenant).count).to eq(1)

      result = described_class.call(financial_source, days: 30)

      expect(FinancialReceivable.where(tenant: tenant).count).to eq(1)
      expect(result.created_count).to eq(0)
      expect(result.updated_count).to eq(1)
    end
  end

  describe "authentication failure" do
    it "marks the financial source as errored" do
      stub_request(:get, "https://api.pagar.me/core/v5/payables")
        .to_return(status: 401, body: { message: "Unauthorized" }.to_json)

      result = described_class.call(financial_source, days: 30)

      expect(result.error?).to eq(true)
      expect(financial_source.reload.status).to eq("error")
    end
  end
end
