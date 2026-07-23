require "rails_helper"

RSpec.describe Integrations::Tiktok::StatementFinancialBackfillService do
  let(:tenant) { Tenant.create!(name: "Loja Statement", slug: "statement-#{SecureRandom.hex(4)}") }
  let(:channel) { Channel.ensure_for!(tenant, "tiktok") }
  let(:credential) do
    tenant.channel_credentials.create!(
      channel: "tiktok",
      status: "active",
      credentials: { app_key: "key", app_secret: "secret", access_token: "token", shop_cipher: "cipher" }
    )
  end
  let(:adapter) { instance_double(Integrations::TiktokAdapter) }
  let(:lock) { instance_double(Integrations::Tiktok::FinancialSyncLock, acquire: true, release: true) }
  let(:statement) { { "id" => "statement-1", "statement_time" => 1_751_068_800, "payment_status" => "PAID" } }
  let(:transaction) do
    {
      "id" => "transaction-1",
      "type" => "ORDER",
      "order_id" => "order-1",
      "revenue_amount" => "100",
      "settlement_amount" => "80",
      "fee_tax_amount" => "20",
      "shipping_cost_amount" => "0",
      "fee_tax_breakdown" => {
        "fee" => {
          "platform_commission_amount" => "-10",
          "affiliate_commission_amount" => "-5",
          "fee_per_item_sold_amount" => "-2",
          "sfp_service_fee_amount" => "-3"
        }
      }
    }
  end

  before do
    allow(Integrations::TiktokAdapter).to receive(:new).and_return(adapter)
    allow(Integrations::Tiktok::FinancialSyncLock).to receive(:new).and_return(lock)
    allow(adapter).to receive(:fetch_financial_statements).and_return([ statement ])
    allow(adapter).to receive(:fetch_statement_transactions).and_return([ transaction ])
  end

  it "updates an existing order and does not create a missing order" do
    order = tenant.orders.create!(channel: channel, external_id: "order-1", status: "COMPLETED")

    result = described_class.call(credential, date_from: "2026-07-01", date_to: "2026-07-01", run_id: "run-1")

    expect(result.success?).to eq(true)
    expect(order.reload.settlement_amount).to eq(BigDecimal("80"))
    expect(order.reload.financial_breakdown.dig("transactions", 0, "id")).to eq("transaction-1")
    expect(tenant.orders.where(external_id: "missing")).to be_empty
  end

  it "skips a successful statement on the second run without force" do
    order = tenant.orders.create!(channel: channel, external_id: "order-1", status: "COMPLETED")

    described_class.call(credential, date_from: "2026-07-01", date_to: "2026-07-01", run_id: "run-1")
    described_class.call(credential, date_from: "2026-07-01", date_to: "2026-07-01", run_id: "run-2")

    expect(adapter).to have_received(:fetch_statement_transactions).once
    expect(order.reload.financial_synced_at).to be_present
  end

  it "reprocesses a statement explicitly with force" do
    order = tenant.orders.create!(channel: channel, external_id: "order-1", status: "COMPLETED")

    described_class.call(credential, date_from: "2026-07-01", date_to: "2026-07-01", run_id: "run-1")
    described_class.call(credential, date_from: "2026-07-01", date_to: "2026-07-01", force: true, run_id: "run-2")

    expect(adapter).to have_received(:fetch_statement_transactions).twice
  end
end
