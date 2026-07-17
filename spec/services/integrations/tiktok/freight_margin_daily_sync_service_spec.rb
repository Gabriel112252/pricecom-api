require "rails_helper"

RSpec.describe Integrations::Tiktok::FreightMarginDailySyncService do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:channel) { Channel.ensure_for!(tenant, "tiktok") }
  let(:ordered_at) { Time.zone.local(2026, 7, 16, 10, 0, 0) }

  def upsert_tiktok_order(external_id:, freight:, original_shipping_fee:, status: "COMPLETED")
    channel

    Integrations::Orders::UpsertOrder.call(
      tenant: tenant,
      provider: "tiktok",
      normalized: {
        external_id: external_id,
        order_number: external_id,
        status: status,
        payment_method: "PIX",
        customer_name: "Cliente Teste",
        customer_tag: "novo",
        state: "SP",
        order_type: "sale",
        refund_amount: 0,
        nf_gross_value: 0,
        nf_discount: 0,
        nf_freight: 0,
        gross_value: 100 + freight.to_f,
        freight: freight,
        original_shipping_fee: original_shipping_fee,
        shipping_fee_platform_discount: 0,
        shipping_fee_seller_discount: 0,
        discount: 0,
        ordered_at: ordered_at,
        items: [
          {
            sku: "SKU-#{external_id}",
            name: "Produto Teste",
            quantity: 1,
            unit_price: 100,
            unit_cost: 40,
            discount: 0,
            is_gift: false,
            nf_unit_price: 0
          }
        ]
      }
    )
  end

  def daily
    tenant.freight_margin_dailies.find_by!(channel: channel, date: Date.new(2026, 7, 16))
  end

  it "records near-zero freight margin for a fully subsidized TikTok order" do
    result = upsert_tiktok_order(
      external_id: "584933315891857246",
      freight: 18.64,
      original_shipping_fee: 18.64
    )

    expect(result.success?).to eq(true)
    expect(daily.order_count).to eq(1)
    expect(daily.freight_charged).to eq(BigDecimal("18.64"))
    expect(daily.freight_cost).to eq(BigDecimal("18.64"))
    expect(daily.margin_value).to eq(BigDecimal("0.00"))
    expect(daily.margin_percent).to eq(BigDecimal("0.00"))
  end

  it "records negative freight margin for a partially subsidized TikTok order" do
    result = upsert_tiktok_order(
      external_id: "584933315891857248",
      freight: 6.84,
      original_shipping_fee: 18.64
    )

    expect(result.success?).to eq(true)
    expect(daily.freight_charged).to eq(BigDecimal("6.84"))
    expect(daily.freight_cost).to eq(BigDecimal("18.64"))
    expect(daily.margin_value).to eq(BigDecimal("-11.80"))
    expect(daily.margin_percent).to eq(BigDecimal("-172.51"))
  end

  it "records freight margin from shipping_fee minus original_shipping_fee when there is no subsidy" do
    result = upsert_tiktok_order(
      external_id: "584933315891857249",
      freight: 20.00,
      original_shipping_fee: 18.64
    )

    expect(result.success?).to eq(true)
    expect(daily.freight_charged).to eq(BigDecimal("20.00"))
    expect(daily.freight_cost).to eq(BigDecimal("18.64"))
    expect(daily.margin_value).to eq(BigDecimal("1.36"))
    expect(daily.margin_percent).to eq(BigDecimal("6.80"))
  end

  it "does not create freight-margin rows for TikTok unpaid orders" do
    result = upsert_tiktok_order(
      external_id: "584933315891857250",
      freight: 6.84,
      original_shipping_fee: 18.64,
      status: "unpaid"
    )

    expect(result.success?).to eq(true)
    expect(tenant.freight_margin_dailies.where(channel: channel)).to be_empty
  end
end
