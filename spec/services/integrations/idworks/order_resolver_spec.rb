require "rails_helper"

RSpec.describe Integrations::Idworks::OrderResolver do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:channel) { tenant.channels.create!(name: "Yampi", platform: "yampi") }
  let(:integration) { tenant.integrations.create!(provider: "idworks", name: "idworks", status: "connected", credentials: {}) }
  let(:resolver) { described_class.new(tenant: tenant, integration: integration) }

  def make_order(order_number: nil, external_id: nil)
    tenant.orders.create!(
      channel: channel, order_number: order_number, external_id: external_id,
      order_type: "sale", gross_value: 100, ordered_at: Time.current
    )
  end

  it "matches by exact order_number against order_ref" do
    order = make_order(order_number: "555001")

    result = resolver.resolve(order_ref: "555001", idworks_order_id: "88001")

    expect(result[:order]).to eq(order)
    expect(result[:reason]).to be_nil
  end

  it "matches via a normalized comparison when formatting/casing differs (not just digits)" do
    order = make_order(order_number: "ABC001")

    result = resolver.resolve(order_ref: "abc-001", idworks_order_id: "88001")

    expect(result[:order]).to eq(order)
    expect(result[:match_strategy]).to eq(:normalized)
  end

  it "resolves a batch with the same result as resolving each order individually" do
    exact_order = make_order(order_number: "555001")
    normalized_order = make_order(order_number: "ABC002")
    raw_orders = [
      { order_ref: "555001", idworks_order_id: "88001" },
      { order_ref: "abc-002", idworks_order_id: "88002" },
      { order_ref: "999999", idworks_order_id: "88003" }
    ]

    batch_results = resolver.resolve_many(raw_orders)

    expect(batch_results.map { |result| result[:order] }).to eq([ exact_order, normalized_order, nil ])
    expect(batch_results.map { |result| result[:reason] }).to eq([ nil, nil, "order_not_found" ])
    expect(batch_results[1][:match_strategy]).to eq(:normalized)
  end

  it "resolves a batch through an integration mapping scoped to the Idworks integration" do
    order = make_order
    IntegrationMapping.create!(
      tenant: tenant, integration: integration, mappable: order,
      external_type: "order", external_id: "88004", external_code: "MAP-004", status: "active"
    )

    result = resolver.resolve_many([{ order_ref: nil, idworks_order_id: "88004" }]).first

    expect(result[:order]).to eq(order)
    expect(result[:match_source]).to eq("IDOrder")
  end

  it "returns order_not_found when no candidate reference matches" do
    result = resolver.resolve(order_ref: "999999", idworks_order_id: "88001")

    expect(result[:order]).to be_nil
    expect(result[:reason]).to eq("order_not_found")
  end

  it "returns missing_external_reference when the raw order has no usable reference" do
    result = resolver.resolve(order_ref: nil, idworks_order_id: nil)

    expect(result[:order]).to be_nil
    expect(result[:reason]).to eq("missing_external_reference")
  end

  it "returns duplicated_reference when more than one Pricecom order matches the same reference" do
    make_order(order_number: "555001")
    make_order(external_id: "555001")

    result = resolver.resolve(order_ref: "555001", idworks_order_id: "88001")

    expect(result[:order]).to be_nil
    expect(result[:reason]).to eq("duplicated_reference")
  end
end
