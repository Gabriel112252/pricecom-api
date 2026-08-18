require "rails_helper"
require "rake"

RSpec.describe "idworks:diagnose_order_matching rake task" do
  before(:all) do
    Rake::Task.define_task(:environment)
    unless Rake::Task.task_defined?("idworks:diagnose_order_matching")
      load Rails.root.join("lib/tasks/idworks_diagnose_order_matching.rake").to_s
    end
  end

  before { Rake::Task["idworks:diagnose_order_matching"].reenable }

  let(:tenant)  { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:channel) { tenant.channels.create!(name: "Yampi", platform: "yampi") }
  let(:integration) do
    tenant.integrations.create!(
      provider: "idworks", name: "idworks", status: "connected",
      credentials: { base_url: "https://cliente.idworks.com.br/1.0", email: "user@hidrabene.com", password: "secret" }
    )
  end
  let(:signin_fixture) { File.read(Rails.root.join("spec/fixtures/integrations/idworks_signin.json")) }
  let!(:matching_order) do
    tenant.orders.create!(
      channel: channel, external_id: "555001", order_number: "555001",
      ordered_at: 1.hour.ago, gross_value: 199.90, order_type: "sale"
    )
  end

  around do |example|
    original = ENV.to_h.slice("TENANT_SLUG", "DAYS", "LIMIT")
    example.run
    %w[TENANT_SLUG DAYS LIMIT].each { |key| ENV[key] = original[key] }
  end

  def stub_idworks_orders(body)
    stub_request(:post, "https://cliente.idworks.com.br/1.0/user/signin/local")
      .to_return(status: 200, body: signin_fixture, headers: { "Content-Type" => "application/json" })
    stub_request(:get, "https://cliente.idworks.com.br/1.0/orders")
      .with(query: hash_including("Page" => "0"))
      .to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })
    stub_request(:get, "https://cliente.idworks.com.br/1.0/orders")
      .with(query: hash_including("Page" => "1"))
      .to_return(status: 200, body: { "Data" => [] }.to_json, headers: { "Content-Type" => "application/json" })
  end

  def invoke
    Rake::Task["idworks:diagnose_order_matching"].invoke
  end

  it "reports a matched order with the real idworks and Pricecom reference values, and never writes anything" do
    integration
    stub_idworks_orders([ { "IDOrder" => 88001, "Order" => "555001" } ])

    ENV["TENANT_SLUG"] = tenant.slug
    ENV["DAYS"] = "30"

    expect { invoke }.not_to change { matching_order.reload.attributes }
    Rake::Task["idworks:diagnose_order_matching"].reenable
    expect { invoke }.to output(
      a_string_including('Order="555001"')
        .and(including("order_number=\"555001\""))
        .and(including("match_source=Order"))
    ).to_stdout
  end

  it "reports an unmatched order with its raw reference and every match attempt tried, so the mismatch is visible" do
    integration
    stub_idworks_orders([ { "IDOrder" => 99002, "Order" => "ERP-INTERNAL-42" } ])

    ENV["TENANT_SLUG"] = tenant.slug
    ENV["DAYS"] = "30"

    expect { invoke }.to output(
      a_string_including('Order="ERP-INTERNAL-42"')
        .and(including("reason=order_not_found"))
        .and(including("tentativa: source=Order"))
    ).to_stdout
  end
end
