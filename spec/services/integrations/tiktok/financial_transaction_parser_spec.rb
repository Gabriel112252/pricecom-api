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
      affiliate_ads_commission_amount: BigDecimal("2.50"),
      affiliate_partner_commission_amount: BigDecimal("1.20"),
      item_fee_amount: BigDecimal("4.00"),
      service_fee_amount: BigDecimal("4.61")
    )
  end

  # Regressão: affiliate_ads_commission_amount e
  # affiliate_partner_commission_amount já eram reconhecidas em FEE_FIELDS,
  # mas caíam no bucket genérico other_fees_amount por não estarem
  # excluídas da soma residual — perdendo a distinção entre comissão de
  # afiliado orgânico, via anúncio pago e via parceiro.
  describe "the three affiliate commission fields stay separate from other_fees_amount" do
    it "sums each of the three affiliate fee keys into its own field, not into other_fees_amount" do
      result = described_class.call(order_payload, origin: :order)

      expect(result[:affiliate_commission_amount]).to eq(BigDecimal("15.37"))
      expect(result[:affiliate_ads_commission_amount]).to eq(BigDecimal("2.50"))
      expect(result[:affiliate_partner_commission_amount]).to eq(BigDecimal("1.20"))
      # other_fees_amount é 0 aqui: todas as chaves do fixture (platform,
      # item, service, os três affiliate_*) já têm campo próprio.
      expect(result[:other_fees_amount]).to eq(BigDecimal("0"))
    end

    it "still buckets a genuinely unrecognized fee key into other_fees_amount" do
      payload = order_payload.deep_dup
      payload["sku_transactions"].first["fee_tax_breakdown"]["fee"]["bonus_cashback_service_fee_amount"] = "-3.33"

      result = described_class.call(payload, origin: :order)

      expect(result[:other_fees_amount]).to eq(BigDecimal("3.33"))
      # Não vaza pros três campos de afiliado nem para os demais nomeados.
      expect(result[:affiliate_commission_amount]).to eq(BigDecimal("15.37"))
      expect(result[:affiliate_ads_commission_amount]).to eq(BigDecimal("2.50"))
      expect(result[:affiliate_partner_commission_amount]).to eq(BigDecimal("1.20"))
    end

    it "defaults all three to zero when the fee breakdown omits them" do
      payload = order_payload.deep_dup
      fee = payload["sku_transactions"].first["fee_tax_breakdown"]["fee"]
      fee.delete("affiliate_ads_commission_amount")
      fee.delete("affiliate_partner_commission_amount")

      result = described_class.call(payload, origin: :order)

      expect(result[:affiliate_ads_commission_amount]).to eq(BigDecimal("0"))
      expect(result[:affiliate_partner_commission_amount]).to eq(BigDecimal("0"))
      expect(result[:affiliate_commission_amount]).to eq(BigDecimal("15.37"))
    end
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

  it "sums the three affiliate commission fields across multiple aggregated rows" do
    row_a = described_class.call(order_payload, origin: :order).merge(transaction_id: "transaction-a")
    row_b = row_a.merge(
      transaction_id: "transaction-b",
      affiliate_commission_amount: BigDecimal("5"),
      affiliate_ads_commission_amount: BigDecimal("1"),
      affiliate_partner_commission_amount: BigDecimal("2")
    )

    aggregate = described_class.aggregate([ row_a, row_b ])

    expect(aggregate[:affiliate_commission_amount]).to eq(BigDecimal("20.37"))
    expect(aggregate[:affiliate_ads_commission_amount]).to eq(BigDecimal("3.50"))
    expect(aggregate[:affiliate_partner_commission_amount]).to eq(BigDecimal("3.20"))
  end

  it "rejects an incomplete order transaction" do
    incomplete = order_payload.except("settlement_amount")

    expect { described_class.call(incomplete, origin: :order) }
      .to raise_error(Integrations::Tiktok::FinancialTransactionParser::InvalidTransactionError)
  end
end
