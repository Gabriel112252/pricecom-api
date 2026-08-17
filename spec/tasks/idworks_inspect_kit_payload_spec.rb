require "rails_helper"
require "rake"

RSpec.describe "idworks:inspect_kit_payload rake task" do
  before(:all) do
    Rake::Task.define_task(:environment)
    unless Rake::Task.task_defined?("idworks:inspect_kit_payload")
      load Rails.root.join("lib/tasks/idworks_inspect_kit_payload.rake").to_s
    end
  end

  before { Rake::Task["idworks:inspect_kit_payload"].reenable }

  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:signin_fixture) { File.read(Rails.root.join("spec/fixtures/integrations/idworks_signin.json")) }

  around do |example|
    original = ENV.to_h.slice("DAYS", "TENANT_SLUG")
    example.run
    ENV["DAYS"] = original["DAYS"]
    ENV["TENANT_SLUG"] = original["TENANT_SLUG"]
  end

  it "finds orders with a kit item (IDSkuKit or KitSkuName present) and prints their full raw payload" do
    tenant.integrations.create!(
      provider: "idworks", name: "idworks", status: "connected",
      credentials: { base_url: "https://cliente.idworks.com.br/1.0", email: "user@hidrabene.com", password: "secret" }
    )

    stub_request(:post, "https://cliente.idworks.com.br/1.0/user/signin/local")
      .to_return(status: 200, body: signin_fixture, headers: { "Content-Type" => "application/json" })
    stub_request(:get, "https://cliente.idworks.com.br/1.0/orders")
      .with(query: hash_including("Page" => "0"))
      .to_return(
        status: 200,
        body: [
          { "IDOrder" => 1, "Order" => "N1", "Items" => [ { "IDSkuCompany" => "SOLO", "IDSkuKit" => nil, "KitSkuName" => nil, "Quantity" => 1 } ] },
          { "IDOrder" => 2, "Order" => "N2", "Items" => [
            { "IDSkuCompany" => "0107", "IDSkuKit" => 9001, "KitSkuName" => "Kit Clareador", "QuantityKit" => 1, "Quantity" => 1 },
            { "IDSkuCompany" => "2080", "IDSkuKit" => 9001, "KitSkuName" => "Kit Clareador", "QuantityKit" => 1, "Quantity" => 1 }
          ] }
        ].to_json,
        headers: { "Content-Type" => "application/json" }
      )
    stub_request(:get, "https://cliente.idworks.com.br/1.0/orders")
      .with(query: hash_including("Page" => "1"))
      .to_return(status: 200, body: [].to_json, headers: { "Content-Type" => "application/json" })

    ENV["TENANT_SLUG"] = tenant.slug
    ENV["DAYS"] = "30"

    output = capture_stdout { Rake::Task["idworks:inspect_kit_payload"].invoke }

    expect(output).to include("pedidos com item de kit encontrados")
    expect(output).to include('"Kit Clareador"')
    expect(output).not_to include('"IDOrder": 1')
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end
end
