require "rails_helper"
require "rake"

RSpec.describe "idworks:inspect_order_payload rake task" do
  before(:all) do
    Rake::Task.define_task(:environment)
    unless Rake::Task.task_defined?("idworks:inspect_order_payload")
      load Rails.root.join("lib/tasks/idworks_inspect_order_payload.rake").to_s
    end
  end

  before { Rake::Task["idworks:inspect_order_payload"].reenable }

  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:signin_fixture) { File.read(Rails.root.join("spec/fixtures/integrations/idworks_signin.json")) }

  around do |example|
    original = ENV.to_h.slice("DAYS", "TENANT_SLUG")
    example.run
    ENV["DAYS"] = original["DAYS"]
    ENV["TENANT_SLUG"] = original["TENANT_SLUG"]
  end

  it "surfaces a channel-like key and its distinct values from the raw idworks payload, without normalizing it away" do
    tenant.integrations.create!(
      provider: "idworks", name: "idworks", status: "connected",
      credentials: { base_url: "https://cliente.idworks.com.br/1.0", email: "user@hidrabene.com", password: "secret" }
    )

    stub_request(:post, "https://cliente.idworks.com.br/1.0/user/signin/local")
      .to_return(status: 200, body: signin_fixture, headers: { "Content-Type" => "application/json" })

    # Payload sintético só pra provar que o heurístico de detecção funciona
    # — o campo/valores REAIS do idworks ainda não foram confirmados (ver
    # comentário do task); "MarketplaceOrigin"/"ML" aqui é só um exemplo.
    stub_request(:get, "https://cliente.idworks.com.br/1.0/orders")
      .with(query: hash_including("Page" => "0"))
      .to_return(
        status: 200,
        body: [
          { "IDOrder" => 1, "Order" => "555001", "MarketplaceOrigin" => "ML" },
          { "IDOrder" => 2, "Order" => "555002", "MarketplaceOrigin" => "YAMPI" }
        ].to_json,
        headers: { "Content-Type" => "application/json" }
      )

    ENV["TENANT_SLUG"] = tenant.slug
    ENV["DAYS"] = "30"

    output = capture_stdout { Rake::Task["idworks:inspect_order_payload"].invoke }

    expect(output).to include('"MarketplaceOrigin"')
    expect(output).to include('["ML", "YAMPI"]')
  end

  it "finds the integration regardless of its status (production integrations aren't always literally 'connected')" do
    tenant.integrations.create!(
      provider: "idworks", name: "idworks", status: "error",
      credentials: { base_url: "https://cliente.idworks.com.br/1.0", email: "user@hidrabene.com", password: "secret" }
    )

    stub_request(:post, "https://cliente.idworks.com.br/1.0/user/signin/local")
      .to_return(status: 200, body: signin_fixture, headers: { "Content-Type" => "application/json" })
    stub_request(:get, "https://cliente.idworks.com.br/1.0/orders")
      .with(query: hash_including("Page" => "0"))
      .to_return(status: 200, body: [ { "IDOrder" => 1, "Order" => "555001" } ].to_json, headers: { "Content-Type" => "application/json" })

    ENV["TENANT_SLUG"] = tenant.slug
    ENV["DAYS"] = "30"

    output = capture_stdout { Rake::Task["idworks:inspect_order_payload"].invoke }

    expect(output).to include("pedidos recebidos")
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
