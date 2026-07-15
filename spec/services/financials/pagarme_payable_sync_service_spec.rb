require "rails_helper"

RSpec.describe Financials::PagarmePayableSyncService do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:channel) { tenant.channels.create!(name: "Yampi", platform: "yampi") }
  let(:financial_source) do
    tenant.financial_sources.create!(
      provider: "pagarme",
      name: "Pagar.me",
      source_type: "gateway",
      status: "active",
      credentials: { api_key: "sk_test_abc123" }
    )
  end
  let(:payables_url) { "https://api.pagar.me/core/v5/payables" }
  let!(:order_by_charge) do
    tenant.orders.create!(
      channel: channel,
      external_id: "YAMPI-555001",
      order_number: "555001",
      ordered_at: Time.zone.parse("2026-07-10T10:00:00Z"),
      gross_value: 199.90,
      order_type: "sale"
    )
  end
  let!(:order_by_transaction) do
    tenant.orders.create!(
      channel: channel,
      external_id: "YAMPI-555002",
      order_number: "555002",
      ordered_at: Time.zone.parse("2026-07-11T10:00:00Z"),
      gross_value: 50.00,
      order_type: "sale"
    )
  end
  let!(:legacy_settlement) do
    financial_source.financial_settlements.create!(
      tenant: tenant,
      channel: channel,
      external_id: "legacy-charges",
      period_start: Date.new(2026, 7, 1),
      period_end: Date.new(2026, 7, 15),
      status: "paid"
    )
  end
  let!(:legacy_charge_item) do
    legacy_settlement.financial_settlement_items.create!(
      tenant: tenant,
      order: order_by_charge,
      external_id: "ch_charge_lookup",
      external_order_id: order_by_charge.external_id,
      transaction_type: "sale",
      gross_amount: 199.90,
      net_amount: 199.90,
      status: "matched"
    )
  end
  let!(:legacy_transaction_item) do
    legacy_settlement.financial_settlement_items.create!(
      tenant: tenant,
      order: order_by_transaction,
      external_id: "legacy-transaction-link",
      external_order_id: order_by_transaction.external_id,
      transaction_type: "sale",
      gross_amount: 50.00,
      net_amount: 50.00,
      status: "matched",
      metadata: { "pagarme_transaction_id" => "tran_fallback_lookup" }
    )
  end
  let(:page_1) do
    {
      data: [
        {
          id: "pay_charge",
          status: "waiting_funds",
          amount: 19990,
          fee: 1000,
          anticipation_fee: 550,
          installment: 1,
          transaction_id: "tran_charge",
          charge_id: "ch_charge_lookup",
          recipient_id: "rp_1",
          payment_date: "2026-07-20",
          original_payment_date: "2026-08-01",
          payment_method: "credit_card",
          accrual_date: "2026-07-10T12:00:00Z",
          date_created: "2026-07-10T12:00:01Z"
        }
      ],
      paging: { forward_cursor: "cursor_2" }
    }.to_json
  end
  let(:page_2) do
    {
      data: [
        {
          id: "pay_transaction",
          status: "paid",
          amount: 5000,
          fee: 125,
          anticipation_fee: 0,
          installment: 1,
          transaction_id: "tran_fallback_lookup",
          recipient_id: "rp_1",
          payment_date: "2026-07-21",
          original_payment_date: "2026-07-21",
          payment_method: "pix",
          accrual_date: "2026-07-11T12:00:00Z",
          date_created: "2026-07-11T12:00:01Z"
        }
      ],
      paging: { forward_cursor: nil }
    }.to_json
  end

  before do
    travel_to Time.zone.parse("2026-07-15T12:00:00Z")

    stub_request(:get, payables_url)
      .with(query: { "payment_date[gte]" => "2026-07-01", "payment_date[lte]" => "2026-07-31", "size" => "30" })
      .to_return(status: 200, body: page_1, headers: { "Content-Type" => "application/json" })

    stub_request(:get, payables_url)
      .with(query: { "payment_date[gte]" => "2026-07-01", "payment_date[lte]" => "2026-07-31", "size" => "30", "forward_cursor" => "cursor_2" })
      .to_return(status: 200, body: page_2, headers: { "Content-Type" => "application/json" })
  end

  after { travel_back }

  it "upserts payables idempotently and links orders by charge_id then transaction_id fallback" do
    result = described_class.call(financial_source, from: "2026-07-01", to: "2026-07-31")

    expect(result.success?).to eq(true)
    expect(result.created_count).to eq(2)
    expect(result.updated_count).to eq(0)
    expect(FinancialReceivable.where(tenant: tenant).count).to eq(2)

    charge_receivable = FinancialReceivable.find_by!(payable_id: "pay_charge")
    expect(charge_receivable.order).to eq(order_by_charge)
    expect(charge_receivable.financial_settlement_item.order).to eq(order_by_charge)
    expect(charge_receivable.fee_amount).to eq(BigDecimal("10.0"))
    expect(charge_receivable.anticipation_fee_amount).to eq(BigDecimal("5.5"))
    expect(charge_receivable.net_amount).to eq(BigDecimal("184.4"))
    expect(charge_receivable.financial_settlement_item.fee_amount).to eq(BigDecimal("15.5"))

    transaction_receivable = FinancialReceivable.find_by!(payable_id: "pay_transaction")
    expect(transaction_receivable.order).to eq(order_by_transaction)
    expect(transaction_receivable.financial_settlement_item.order).to eq(order_by_transaction)
  end

  it "does not duplicate payables or settlement items on a repeated sync" do
    described_class.call(financial_source, from: "2026-07-01", to: "2026-07-31")
    result = described_class.call(financial_source, from: "2026-07-01", to: "2026-07-31")

    expect(result.created_count).to eq(0)
    expect(result.updated_count).to eq(2)
    expect(FinancialReceivable.where(tenant: tenant).count).to eq(2)
    expect(FinancialSettlementItem.where(tenant: tenant, external_id: [ "pay_charge", "pay_transaction" ]).count).to eq(2)
  end

  it "logs the payable sync window" do
    described_class.call(financial_source, from: "2026-07-01", to: "2026-07-31")

    log = IntegrationSyncLog.where(tenant: tenant, action: "pagarme_payable_sync").last
    expect(log.status).to eq("success")
    expect(log.metadata["created_count"]).to eq(2)
    expect(log.metadata["from"]).to eq("2026-07-01")
    expect(log.metadata["to"]).to eq("2026-07-31")
  end
end
