require "rails_helper"

RSpec.describe Integrations::Shopee::OrderEscrowSyncService do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:channel) { tenant.channels.create!(name: "Shopee", platform: "shopee") }
  let(:credential) do
    tenant.channel_credentials.create!(
      channel: "shopee",
      status: "active",
      credentials: {
        "partner_id" => "2011234",
        "partner_key" => "partner-secret",
        "shop_id" => "9001",
        "access_token" => "sp-access",
        "refresh_token" => "sp-refresh"
      }
    )
  end
  let(:order) do
    tenant.orders.create!(
      channel: channel,
      external_id: "SN-1",
      order_number: "SN-1",
      status: "COMPLETED",
      gross_value: 115.0,
      freight: 15.0,
      discount: 20.0,
      ordered_at: Time.current
    )
  end
  let(:adapter) { instance_double(Integrations::ShopeeAdapter) }

  # order_income realista: 2 × 50.00 de produto, 10.00 de desconto seller,
  # 5.00 de voucher seller, subsídios Shopee que NÃO reduzem a receita,
  # taxas negativas (convenção Shopee) e frete líquido saindo do seller.
  let(:order_income) do
    {
      "original_price" => 100.0,
      "seller_discount" => -10.0,
      "voucher_from_seller" => -5.0,
      "shopee_discount" => -7.0,
      "voucher_from_shopee" => -3.0,
      "buyer_paid_shipping_fee" => 15.0,
      "commission_fee" => -14.0,
      "service_fee" => -6.0,
      "seller_transaction_fee" => -2.0,
      "actual_shipping_fee" => 18.0,
      "shopee_shipping_rebate" => 3.0,
      "final_shipping_fee" => -15.0,
      "escrow_amount" => 63.0
    }
  end
  let(:escrow_response) { { "order_sn" => "SN-1", "order_income" => order_income } }

  before do
    allow(adapter).to receive(:fetch_escrow_detail).with("SN-1").and_return(escrow_response)
  end

  def sync!
    described_class.call(order: order, channel_credential: credential, adapter: adapter)
  end

  it "maps order_income to the TikTok-style Order financial columns" do
    sync!
    order.reload

    # revenue = 100 − 10 (seller_discount) − 5 (voucher seller) + 15 (frete
    # pago pelo comprador) — subsídios Shopee ficam de fora, mesma régua do
    # platform_discount do TikTok.
    expect(order.revenue_amount).to eq(100.0)
    expect(order.settlement_amount).to eq(63.0)
    expect(order.fee_and_tax_amount).to eq(22.0)
    expect(order.shipping_cost_amount).to eq(15.0)
    expect(order.platform_commission_amount).to eq(14.0)
    expect(order.service_fee_amount).to eq(6.0)
    expect(order.item_fee_amount).to eq(2.0)
    expect(order.commission).to eq(22.0)
    expect(order.financial_synced_at).to be_present
  end

  it "records the raw payload and the arithmetic delta for sandbox auditing" do
    sync!
    order.reload

    expect(order.financial_breakdown["order_income"]).to include("escrow_amount" => 63.0)
    # revenue(100) − fees(22) − shipping(15) − settlement(63) = 0
    expect(order.financial_breakdown.dig("_pricecom", "arithmetic_delta")).to eq(0.0)
  end

  it "fills the freight audit trio from the escrow (original_shipping_fee equivalent)" do
    sync!
    order.reload

    expect(order.original_shipping_fee).to eq(18.0)
    expect(order.shipping_fee_platform_discount).to eq(3.0)
  end

  it "raises PendingEscrowError when order_income is not available yet" do
    allow(adapter).to receive(:fetch_escrow_detail).with("SN-1").and_return({ "order_sn" => "SN-1" })

    expect { sync! }.to raise_error(described_class::PendingEscrowError)
    expect(order.reload.financial_synced_at).to be_nil
  end

  it "does not refetch an already-synced order unless forced" do
    order.update!(financial_synced_at: 1.hour.ago)

    sync!

    expect(adapter).not_to have_received(:fetch_escrow_detail)
  end

  it "treats a positive final_shipping_fee (refund to seller) as zero shipping cost" do
    order_income["final_shipping_fee"] = 4.0

    sync!

    expect(order.reload.shipping_cost_amount).to eq(0.0)
  end
end
