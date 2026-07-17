require "rails_helper"

RSpec.describe FinancialSettlementItem do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:channel) { tenant.channels.create!(name: "Yampi", platform: "yampi") }
  let(:financial_source) do
    tenant.financial_sources.create!(provider: "pagarme", name: "Pagar.me", source_type: "gateway", status: "active")
  end
  let(:settlement) do
    financial_source.financial_settlements.create!(
      tenant: tenant, channel: channel, external_id: "settle-1",
      period_start: Date.current, period_end: Date.current, status: "paid"
    )
  end

  def build_item(**overrides)
    settlement.financial_settlement_items.new(
      { tenant: tenant, external_id: "item-1", transaction_type: "sale", gross_amount: 100, net_amount: 90 }.merge(overrides)
    )
  end

  it "rejects negative gross_amount/net_amount for a sale" do
    item = build_item(transaction_type: "sale", gross_amount: -50, net_amount: -50)

    expect(item).not_to be_valid
    expect(item.errors[:gross_amount]).to be_present
    expect(item.errors[:net_amount]).to be_present
  end

  it "accepts negative gross_amount/net_amount for a refund (money going out)" do
    item = build_item(transaction_type: "refund", gross_amount: -101.03, net_amount: -101.03)

    expect(item).to be_valid
  end

  it "still rejects a negative fee_amount even for a refund" do
    item = build_item(transaction_type: "refund", gross_amount: -101.03, net_amount: -101.03, fee_amount: -5)

    expect(item).not_to be_valid
    expect(item.errors[:fee_amount]).to be_present
  end

  describe "#refund?" do
    it "is true only for transaction_type refund" do
      expect(build_item(transaction_type: "refund")).to be_refund
      expect(build_item(transaction_type: "sale")).not_to be_refund
    end
  end
end
