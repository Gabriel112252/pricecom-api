require "rails_helper"

RSpec.describe "idworks integration", type: :request do
  let(:tenant)   { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:admin)    { tenant.users.create!(name: "Admin", email: "admin@#{SecureRandom.hex(4)}.com", password: "password123", role: "admin") }
  let(:operador) { tenant.users.create!(name: "Operador", email: "op@#{SecureRandom.hex(4)}.com", password: "password123", role: "operador") }
  let(:signin_fixture) { File.read(Rails.root.join("spec/fixtures/integrations/idworks_signin.json")) }
  let(:sku_fixture)    { File.read(Rails.root.join("spec/fixtures/integrations/idworks_sku_list.json")) }
  let(:orders_fixture) { File.read(Rails.root.join("spec/fixtures/integrations/idworks_orders_list.json")) }
  let(:base_url) { "https://cliente.idworks.com.br/1.0" }

  def auth_headers(user)
    { "Authorization" => "Bearer #{JsonWebToken.encode(user_id: user.id)}" }
  end

  def stub_signin(status: 200)
    stub_request(:post, "#{base_url}/user/signin/local")
      .to_return(status: status, body: status == 200 ? signin_fixture : { message: "Invalid credentials" }.to_json,
                 headers: { "Content-Type" => "application/json" })
  end

  def stub_empty_lists
    stub_request(:get, "#{base_url}/sku").to_return(status: 200, body: { "Data" => [] }.to_json, headers: { "Content-Type" => "application/json" })
    stub_request(:get, "#{base_url}/orders").to_return(status: 200, body: { "Data" => [] }.to_json, headers: { "Content-Type" => "application/json" })
  end

  describe "POST /api/v1/integrations/idworks/connect" do
    it "requires admin" do
      post "/api/v1/integrations/idworks/connect", headers: auth_headers(operador)
      expect(response).to have_http_status(:forbidden)
    end

    it "connects idworks with email/password and seeds cost/freight -> idworks in DataSourceConfig (not tax)" do
      stub_signin

      post "/api/v1/integrations/idworks/connect", headers: auth_headers(admin),
        params: { credentials: { base_url: base_url, email: "user@hidrabene.com", password: "secret" } }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["status"]).to eq("connected")

      expect(DataSourceConfig.source_for(tenant, "cost")).to eq("idworks")
      expect(DataSourceConfig.source_for(tenant, "freight")).to eq("idworks")
      expect(DataSourceConfig.source_for(tenant, "tax")).to be_nil # idworks has no tax data — never defaulted
      expect(DataSourceConfig.source_for(tenant, "payment_reconciliation")).to be_nil
    end

    it "does not overwrite a data_type the tenant already repointed elsewhere" do
      DataSourceConfig.ensure_default!(tenant, "freight", "pagarme")
      stub_signin

      post "/api/v1/integrations/idworks/connect", headers: auth_headers(admin),
        params: { credentials: { base_url: base_url, email: "user@hidrabene.com", password: "secret" } }

      expect(DataSourceConfig.source_for(tenant, "freight")).to eq("pagarme") # untouched
      expect(DataSourceConfig.source_for(tenant, "cost")).to eq("idworks")    # still seeded
    end

    it "marks the integration errored on invalid email/password but still saves the credentials" do
      stub_signin(status: 401)

      post "/api/v1/integrations/idworks/connect", headers: auth_headers(admin),
        params: { credentials: { base_url: base_url, email: "user@hidrabene.com", password: "wrong" } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["errors"]).to eq([ "E-mail ou senha do idworks inválidos." ])
      expect(tenant.integrations.find_by(provider: "idworks").status).to eq("error")
    end
  end

  describe "POST /api/v1/integrations/idworks/sync" do
    it "rejects when idworks isn't connected yet" do
      post "/api/v1/integrations/idworks/sync", headers: auth_headers(admin)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "runs both the product cost sync and order/freight sync" do
      tenant.channels.create!(name: "Yampi", platform: "yampi")
      tenant.products.create!(sku: "CAM-001-P-AZUL", name: "Camiseta", cost_price: 0)
      tenant.products.create!(sku: "CAN-001", name: "Caneca", cost_price: 0)
      tenant.integrations.create!(
        provider: "idworks", name: "idworks", status: "connected",
        credentials: { base_url: base_url, email: "user@hidrabene.com", password: "secret" }
      )
      DataSourceConfig.ensure_defaults_for_source!(tenant, "idworks")

      stub_signin
      # idworks' Page param is 0-indexed — see IdworksAdapter#fetch_products.
      stub_request(:get, "#{base_url}/sku").with(query: hash_including("Page" => "0"))
        .to_return(status: 200, body: sku_fixture, headers: { "Content-Type" => "application/json" })
      stub_request(:get, "#{base_url}/sku").with(query: hash_including("Page" => "1"))
        .to_return(status: 200, body: { "Data" => [] }.to_json, headers: { "Content-Type" => "application/json" })
      stub_request(:get, "#{base_url}/orders").with(query: hash_including("Page" => "0"))
        .to_return(status: 200, body: { "Data" => [] }.to_json, headers: { "Content-Type" => "application/json" })

      post "/api/v1/integrations/idworks/sync", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["success"]).to eq(true)
      expect(body["products_synced_count"]).to eq(2)
      expect(body["orders_synced_count"]).to eq(0)
    end
  end
end
