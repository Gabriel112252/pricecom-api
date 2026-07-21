require "rails_helper"

RSpec.describe Integrations::Tiktok::OrderFinancialSyncService do
  let(:tenant) { Tenant.create!(name: "Hidrabene", slug: "hidrabene-#{SecureRandom.hex(4)}") }
  let(:channel) { Channel.ensure_for!(tenant, "tiktok") }
  let(:channel_credential) do
    tenant.channel_credentials.create!(
      channel: "tiktok",
      status: "active",
      credentials: { app_key: "key", app_secret: "secret", access_token: "tok", shop_cipher: "cipher" }
    )
  end
  let(:adapter) { instance_double(Integrations::TiktokAdapter) }
  let(:statement_response) do
    JSON.parse(File.read(Rails.root.join("spec/fixtures/integrations/tiktok_order_statement_transactions.json")))
  end
  let(:order) do
    tenant.orders.create!(
      channel: channel,
      external_id: "584933315891857248",
      order_number: "584933315891857248",
      status: "COMPLETED",
      order_type: "sale",
      gross_value: 118.90,
      cost_price: 17.23,
      freight: 0,
      discount: 42.04,
      seller_discount: 42.04,
      platform_discount: 6.78
    )
  end

  before do
    allow(adapter).to receive(:fetch_order_statement_transactions)
      .with("584933315891857248")
      .and_return(statement_response)
  end

  def sync_order(current_order: order, credential: channel_credential, current_adapter: adapter)
    described_class.call(
      order: current_order,
      channel_credential: credential,
      adapter: current_adapter
    )
  end

  it "persists the real statement values and recalculates the order margin" do
    expect(Integrations::Orders::UpsertOrder).not_to receive(:call)

    sync_order

    order.reload
    expect(order.revenue_amount).to eq(BigDecimal("76.86"))
    expect(order.fee_and_tax_amount).to eq(BigDecimal("28.59"))
    expect(order.settlement_amount).to eq(BigDecimal("48.27"))
    expect(order.shipping_cost_amount).to eq(BigDecimal("0"))
    expect(order.platform_commission_amount).to eq(BigDecimal("4.61"))
    expect(order.affiliate_commission_amount).to eq(BigDecimal("15.37"))
    expect(order.item_fee_amount).to eq(BigDecimal("4.00"))
    expect(order.service_fee_amount).to eq(BigDecimal("4.61"))
    expect(order.commission).to eq(BigDecimal("28.59"))
    expect(order.margin).to eq(BigDecimal("31.04"))
    expect(order.margin_pct).to eq(BigDecimal("26.11"))
    expect(order.financial_breakdown).to eq(statement_response["data"])
    expect(order.financial_synced_at).to be_present
  end

  it "is idempotent and does not recreate order items or alter order pricing fields" do
    item = order.order_items.create!(sku: "SKU-1", name: "Produto", quantity: 1, unit_cost: 17.23)
    original_values = order.attributes.slice("gross_value", "discount", "seller_discount", "platform_discount")

    2.times do
      sync_order
    end

    order.reload
    expect(order.order_items.pluck(:id)).to eq([ item.id ])
    expect(order.attributes.slice("gross_value", "discount", "seller_discount", "platform_discount")).to eq(original_values)
    expect(order.commission).to eq(BigDecimal("28.59"))
    expect(order.fee_and_tax_amount).to eq(BigDecimal("28.59"))
    expect(order.margin).to eq(BigDecimal("31.04"))
    expect(adapter).to have_received(:fetch_order_statement_transactions).twice
  end

  it "rejects an unsuccessful Finance API envelope without changing the order" do
    allow(adapter).to receive(:fetch_order_statement_transactions)
      .with("584933315891857248")
      .and_return("code" => 1, "message" => "temporary failure")

    expect {
      sync_order
    }.to raise_error(Integrations::ApiError, /code=1/)

    expect(order.reload.commission).to eq(BigDecimal("0"))
    expect(order.financial_synced_at).to be_nil
  end

  it "classifies a successful response without statement data as pending" do
    allow(adapter).to receive(:fetch_order_statement_transactions)
      .with("584933315891857248")
      .and_return("code" => 0, "data" => {})

    expect { sync_order }
      .to raise_error(Integrations::Tiktok::OrderFinancialSyncService::PendingStatementError)
    expect(order.reload.financial_synced_at).to be_nil
  end

  it "rejects an order belonging to another channel before the external call" do
    order.update!(channel: tenant.channels.create!(name: "Yampi", platform: "yampi"))

    expect { sync_order }
      .to raise_error(ArgumentError, /pertencer ao canal TikTok/)
    expect(adapter).not_to have_received(:fetch_order_statement_transactions)
  end

  it "rejects an order and credential belonging to different tenants" do
    other_tenant = Tenant.create!(name: "Outra Loja", slug: "outra-#{SecureRandom.hex(4)}")
    other_credential = other_tenant.channel_credentials.create!(
      channel: "tiktok",
      status: "active",
      credentials: { app_key: "other-key", app_secret: "other-secret", access_token: "other-token", shop_cipher: "other-cipher" }
    )

    expect { sync_order(credential: other_credential) }
      .to raise_error(ArgumentError, /tenants diferentes/)
    expect(adapter).not_to have_received(:fetch_order_statement_transactions)
  end

  it "rejects a credential that is not TikTok" do
    shopify_credential = tenant.channel_credentials.create!(
      channel: "shopify",
      status: "active",
      credentials: { shop_domain: "loja.myshopify.com", access_token: "shop-token", webhook_secret: "webhook" }
    )

    expect { sync_order(credential: shopify_credential) }
      .to raise_error(ArgumentError, /credencial precisa ser do canal TikTok/)
    expect(adapter).not_to have_received(:fetch_order_statement_transactions)
  end

  it "rejects an inactive TikTok credential" do
    channel_credential.update!(status: "error")

    expect { sync_order }
      .to raise_error(ArgumentError, /credencial TikTok precisa estar ativa/)
    expect(adapter).not_to have_received(:fetch_order_statement_transactions)
  end

  it "rejects an order with a blank external_id" do
    order.update!(external_id: "  ")

    expect { sync_order }
      .to raise_error(ArgumentError, /external_id é obrigatório/)
    expect(adapter).not_to have_received(:fetch_order_statement_transactions)
  end

  it "rejects an invalid data object before changing the order" do
    invalid_response = statement_response.merge("data" => [])
    allow(adapter).to receive(:fetch_order_statement_transactions)
      .with("584933315891857248")
      .and_return(invalid_response)
    order.update!(commission: 7.50)
    original_margin = order.margin

    expect { sync_order }
      .to raise_error(Integrations::ApiError, /data inválido/)

    order.reload
    expect(order.commission).to eq(BigDecimal("7.50"))
    expect(order.margin).to eq(original_margin)
    expect(order.financial_synced_at).to be_nil
  end

  it "rejects a non-numeric required financial field without partial persistence" do
    invalid_response = statement_response.deep_dup
    invalid_response["data"]["revenue_amount"] = "not-a-number"
    allow(adapter).to receive(:fetch_order_statement_transactions)
      .with("584933315891857248")
      .and_return(invalid_response)
    order.update!(commission: 7.50)
    original_margin = order.margin

    expect { sync_order }
      .to raise_error(Integrations::ApiError, /revenue_amount inválido/)

    order.reload
    expect(order.commission).to eq(BigDecimal("7.50"))
    expect(order.margin).to eq(original_margin)
    expect(order.financial_synced_at).to be_nil
  end

  it "rejects a non-numeric fee breakdown value without partial persistence" do
    invalid_response = statement_response.deep_dup
    fee = invalid_response["data"]["sku_transactions"][0]["fee_tax_breakdown"]["fee"]
    fee["affiliate_commission_amount"] = "corrupted"
    allow(adapter).to receive(:fetch_order_statement_transactions)
      .with("584933315891857248")
      .and_return(invalid_response)
    order.update!(commission: 7.50)
    original_margin = order.margin

    expect { sync_order }
      .to raise_error(Integrations::ApiError, /affiliate_commission_amount inválido/)

    order.reload
    expect(order.commission).to eq(BigDecimal("7.50"))
    expect(order.margin).to eq(original_margin)
    expect(order.financial_synced_at).to be_nil
  end

  it "treats an absent optional fee as zero" do
    response_without_optional_fee = statement_response.deep_dup
    fee = response_without_optional_fee["data"]["sku_transactions"][0]["fee_tax_breakdown"]["fee"]
    fee.delete("affiliate_commission_amount")
    allow(adapter).to receive(:fetch_order_statement_transactions)
      .with("584933315891857248")
      .and_return(response_without_optional_fee)

    sync_order

    expect(order.reload.affiliate_commission_amount).to eq(BigDecimal("0"))
  end

  it "performs the HTTP request before entering the database lock" do
    events = []
    allow(adapter).to receive(:fetch_order_statement_transactions)
      .with("584933315891857248")
      .and_wrap_original do |_original, _external_id|
        events << :http
        statement_response
      end
    allow(order).to receive(:with_lock) do |&block|
      events << :lock
      block.call
    end

    sync_order

    expect(events).to eq([ :http, :lock ])
  end

  it "preserves the financial commission when RecalculateFinancials runs later" do
    order.order_items.create!(sku: "SKU-1", name: "Produto", quantity: 1, unit_cost: 17.23)

    sync_order
    expect(order.reload.commission).to eq(BigDecimal("28.59"))

    Orders::RecalculateFinancials.call(order, run_audit: false)

    order.reload
    expect(order.commission).to eq(BigDecimal("28.59"))
    expect(order.margin).to eq(BigDecimal("31.04"))
    expect(order.margin_pct).to eq(BigDecimal("26.11"))
  end
end
