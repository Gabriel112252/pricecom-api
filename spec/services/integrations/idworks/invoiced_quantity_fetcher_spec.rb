require "rails_helper"

RSpec.describe Integrations::Idworks::InvoicedQuantityFetcher do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:integration) do
    tenant.integrations.create!(
      provider: "idworks", name: "idworks", status: "connected",
      credentials: { base_url: "https://cliente.idworks.com.br/1.0", email: "user@hidrabene.com", password: "secret" }
    )
  end
  let(:signin_fixture)      { File.read(Rails.root.join("spec/fixtures/integrations/idworks_signin.json")) }
  let(:order_items_fixture) { File.read(Rails.root.join("spec/fixtures/integrations/idworks_orders_skuview_page0.json")) }
  let(:invoice_fixture)     { File.read(Rails.root.join("spec/fixtures/integrations/idworks_invoice_list.json")) }
  let(:base_url) { "https://cliente.idworks.com.br/1.0" }

  def stub_idworks
    stub_request(:post, "#{base_url}/user/signin/local")
      .to_return(status: 200, body: signin_fixture, headers: { "Content-Type" => "application/json" })
    stub_request(:get, "#{base_url}/orders").with(query: hash_including("Page" => "0", "SkuView" => "1"))
      .to_return(status: 200, body: order_items_fixture, headers: { "Content-Type" => "application/json" })
    stub_request(:get, "#{base_url}/orders").with(query: hash_including("Page" => "1"))
      .to_return(status: 200, body: [].to_json, headers: { "Content-Type" => "application/json" })
    stub_request(:get, "#{base_url}/invoice").with(query: hash_including("Page" => "0"))
      .to_return(status: 200, body: invoice_fixture, headers: { "Content-Type" => "application/json" })
    stub_request(:get, "#{base_url}/invoice").with(query: hash_including("Page" => "1"))
      .to_return(status: 200, body: [].to_json, headers: { "Content-Type" => "application/json" })
  end

  it "sums invoiced quantity per base SKU, excluding orders without an issued invoice" do
    stub_idworks

    result = described_class.call(integration, period_from: Date.new(2026, 7, 20), period_to: Date.new(2026, 7, 27))

    # order 1001 (SKU-A qty 3, invoiced) + order 1003 (SKU-A qty 2, NOT invoiced — excluded)
    expect(result["SKU-A"]).to eq(3.0)
    # order 1002 (KIT044 exploded by idworks itself into 0107/2080/0109, qty 1 each, invoiced)
    expect(result["0107"]).to eq(1.0)
    expect(result["0109"]).to eq(1.0)
    # order 1002's "2080" (qty 1) + order 1004's pack "2080_3" already-decomposed (qty 3, invoiced)
    expect(result["2080"]).to eq(4.0)
    expect(result).not_to have_key("KIT044")
  end

  it "plugs into OrderReconciliationService end-to-end with the real (non-stub) fetcher" do
    integration # força a criação da Integration idworks (status connected)
    stub_idworks
    tenant.products.create!(sku: "SKU-A", name: "Produto A", cost_price: 1)
    tenant.products.create!(sku: "2080", name: "Protetor Solar Clareador", cost_price: 1)
    tenant.products.create!(sku: "0107", name: "Sabonete Liquido Facial", cost_price: 1)
    tenant.products.create!(sku: "0109", name: "Serum Multicorretivo", cost_price: 1)

    result = Reconciliation::OrderReconciliationService.call(
      tenant: tenant, period_from: Date.new(2026, 7, 20), period_to: Date.new(2026, 7, 27)
    )

    expect(result.success?).to eq(true)
    expect(ReconciliationItem.find_by(tenant: tenant, sku: "SKU-A").idworks_qty).to eq(3)
    expect(ReconciliationItem.find_by(tenant: tenant, sku: "2080").idworks_qty).to eq(4)
  end

  it "does not call GET /invoice at all when no orders are found in the period" do
    stub_request(:post, "#{base_url}/user/signin/local")
      .to_return(status: 200, body: signin_fixture, headers: { "Content-Type" => "application/json" })
    stub_request(:get, "#{base_url}/orders").with(query: hash_including("Page" => "0", "SkuView" => "1"))
      .to_return(status: 200, body: [].to_json, headers: { "Content-Type" => "application/json" })

    result = described_class.call(integration, period_from: Date.new(2026, 7, 20), period_to: Date.new(2026, 7, 27))

    expect(result).to eq({})
    expect(WebMock).not_to have_requested(:get, "#{base_url}/invoice")
  end
end
