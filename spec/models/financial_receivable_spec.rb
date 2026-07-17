require "rails_helper"

RSpec.describe FinancialReceivable do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:financial_source) do
    tenant.financial_sources.create!(provider: "pagarme", name: "Pagar.me", source_type: "gateway", status: "active")
  end

  def build_receivable(**overrides)
    tenant.financial_receivables.new(
      { financial_source: financial_source, payable_id: "pay-1", status: "paid", amount: 100, net_amount: 90 }.merge(overrides)
    )
  end

  it "accepts a negative amount/net_amount (refund payable — money going out)" do
    receivable = build_receivable(amount: -101.03, net_amount: -101.03)

    expect(receivable).to be_valid
  end

  it "still rejects a negative fee_amount" do
    receivable = build_receivable(amount: -101.03, net_amount: -101.03, fee_amount: -5)

    expect(receivable).not_to be_valid
    expect(receivable.errors[:fee_amount]).to be_present
  end

  it "still rejects a negative anticipation_fee_amount" do
    receivable = build_receivable(anticipation_fee_amount: -1)

    expect(receivable).not_to be_valid
    expect(receivable.errors[:anticipation_fee_amount]).to be_present
  end
end
