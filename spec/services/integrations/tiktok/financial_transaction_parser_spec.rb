require "rails_helper"

RSpec.describe Integrations::Tiktok::FinancialTransactionParser do
  let(:order_payload) do
    JSON.parse(File.read(Rails.root.join("spec/fixtures/integrations/tiktok_order_statement_transactions.json")))["data"]
  end

  it "maps the order endpoint and keeps platform/affiliate fees separate" do
    result = described_class.call(order_payload, origin: :order)

    expect(result).to include(
      order_id: "584933315891857248",
      revenue_amount: BigDecimal("76.86"),
      settlement_amount: BigDecimal("48.27"),
      fee_and_tax_amount: BigDecimal("28.59"),
      shipping_cost_amount: BigDecimal("0"),
      platform_commission_amount: BigDecimal("4.61"),
      affiliate_commission_amount: BigDecimal("15.37"),
      item_fee_amount: BigDecimal("4.00"),
      service_fee_amount: BigDecimal("4.61")
    )
  end

  it "classifies order, adjustment and reserve statement transactions" do
    base = {
      "order_id" => "order-1",
      "revenue_amount" => "10",
      "settlement_amount" => "8",
      "fee_tax_amount" => "2",
      "shipping_cost_amount" => "0",
      "fee_tax_breakdown" => { "fee" => {} }
    }

    expect(described_class.call(base.merge("type" => "ORDER"), origin: :statement)[:transaction_type]).to eq("order")
    expect(described_class.call(base.merge("type" => "ADJUSTMENT", "adjustment_amount" => "-1"), origin: :statement))
      .to include(transaction_type: "adjustment", processable: false)
    expect(described_class.call({ "type" => "RESERVE", "reserve_amount" => "-2" }, origin: :statement))
      .to include(transaction_type: "reserve", processable: false)
  end

  it "aggregates each transaction once and preserves the supplied raw payload" do
    row = described_class.call(order_payload, origin: :order)
    duplicate = row.merge(transaction_id: "transaction-1")
    aggregate = described_class.aggregate([ duplicate, duplicate ], raw_payload: { "source" => "statement" })

    expect(aggregate[:settlement_amount]).to eq(BigDecimal("48.27"))
    expect(aggregate[:financial_breakdown]).to eq("source" => "statement")
  end

  it "rejects an incomplete order transaction" do
    incomplete = order_payload.except("settlement_amount")

    expect { described_class.call(incomplete, origin: :order) }
      .to raise_error(Integrations::Tiktok::FinancialTransactionParser::InvalidTransactionError)
  end
end
