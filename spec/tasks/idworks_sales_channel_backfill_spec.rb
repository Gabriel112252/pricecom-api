require "rails_helper"
require "rake"

RSpec.describe "idworks:backfill_sales_channel rake task" do
  before(:all) do
    Rake::Task.define_task(:environment)
    unless Rake::Task.task_defined?("idworks:backfill_sales_channel")
      load Rails.root.join("lib/tasks/idworks_sales_channel_backfill.rake").to_s
    end
  end

  before { Rake::Task["idworks:backfill_sales_channel"].reenable }

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
      ordered_at: Time.current, gross_value: 199.90, freight: 19.90, order_type: "sale"
    )
  end

  around do |example|
    original = ENV.to_h.slice("APPLY", "TENANT_SLUG", "FROM", "TO", "WINDOW_DAYS", "SLEEP_BETWEEN_WINDOWS")
    example.run
    %w[APPLY TENANT_SLUG FROM TO WINDOW_DAYS SLEEP_BETWEEN_WINDOWS].each { |key| ENV[key] = original[key] }
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
    Rake::Task["idworks:backfill_sales_channel"].invoke
  end

  it "in dry-run (default), reports what would change without touching the order" do
    integration
    stub_idworks_orders([ { "IDOrder" => 88001, "Order" => "555001", "SalesChannelLogoUrl" => "https://cdn.idworks.com.br/logo/mercadolivre.png" } ])

    ENV["TENANT_SLUG"] = tenant.slug
    ENV["FROM"] = "2026-08-01"
    ENV["TO"] = "2026-08-02"

    expect { invoke }.not_to change { matching_order.reload.idworks_sales_channel }
  end

  it "with APPLY=1, tags the matched order's idworks_sales_channel and touches nothing else (no freight/margin recalculation)" do
    integration
    matching_order.update!(real_freight_cost: nil, margin: nil)
    stub_idworks_orders([ {
      "IDOrder" => 88001, "Order" => "555001", "ValueShipping" => 15.30,
      "SalesChannelLogoUrl" => "https://cdn.idworks.com.br/logo/mercadolivre.png"
    } ])

    ENV["APPLY"] = "1"
    ENV["TENANT_SLUG"] = tenant.slug
    ENV["FROM"] = "2026-08-01"
    ENV["TO"] = "2026-08-02"

    invoke

    matching_order.reload
    expect(matching_order.idworks_sales_channel).to eq("mercadolivre")
    expect(matching_order.real_freight_cost).to be_nil # não tocou frete
  end

  it "skips a tenant that has no idworks integration, without raising" do
    ENV["APPLY"] = "1"
    ENV["TENANT_SLUG"] = tenant.slug
    ENV["FROM"] = "2026-08-01"
    ENV["TO"] = "2026-08-02"

    expect { invoke }.to output(/PULADO/).to_stdout
  end

  it "processes tenants with more than one idworks integration" do
    integration
    tenant.integrations.create!(
      provider: "idworks", name: "idworks Anasol", status: "connected",
      credentials: { base_url: "https://cliente.idworks.com.br/1.0", email: "anasol@example.com", password: "secret" }
    )
    stub_idworks_orders([ { "IDOrder" => 88001, "Order" => "555001", "SalesChannelLogoUrl" => "https://cdn.idworks.com.br/logo/shopee.png" } ])

    ENV["APPLY"] = "1"
    ENV["TENANT_SLUG"] = tenant.slug
    ENV["FROM"] = "2026-08-01"
    ENV["TO"] = "2026-08-02"

    expect { invoke }.to output(/idworks Anasol/).to_stdout
    expect(matching_order.reload.idworks_sales_channel).to eq("shopee")
  end
end
