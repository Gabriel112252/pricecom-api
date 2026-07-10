require "rails_helper"

RSpec.describe "idworks integration", type: :request do
  let(:tenant)   { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:admin)    { tenant.users.create!(name: "Admin", email: "admin@#{SecureRandom.hex(4)}.com", password: "password123", role: "admin") }
  let(:operador) { tenant.users.create!(name: "Operador", email: "op@#{SecureRandom.hex(4)}.com", password: "password123", role: "operador") }
  let(:products_fixture) { File.read(Rails.root.join("spec/fixtures/integrations/idworks_products.json")) }

  def auth_headers(user)
    { "Authorization" => "Bearer #{JsonWebToken.encode(user_id: user.id)}" }
  end

  def stub_auth(status: 200)
    stub_request(:get, "https://cliente.idworks.com.br/api/v1/products")
      .with(query: hash_including("page" => "1"))
      .to_return(status: status, body: status == 200 ? products_fixture : { message: "Unauthenticated" }.to_json,
                 headers: { "Content-Type" => "application/json" })
  end

  describe "POST /api/v1/integrations/idworks/connect" do
    it "requires admin" do
      post "/api/v1/integrations/idworks/connect", headers: auth_headers(operador)
      expect(response).to have_http_status(:forbidden)
    end

    it "connects idworks and seeds cost/tax/freight -> idworks in DataSourceConfig" do
      stub_auth

      post "/api/v1/integrations/idworks/connect", headers: auth_headers(admin),
        params: { credentials: { base_url: "https://cliente.idworks.com.br/api/v1", api_key: "tok" } }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["status"]).to eq("connected")

      %w[cost tax freight].each do |data_type|
        expect(DataSourceConfig.source_for(tenant, data_type)).to eq("idworks")
      end
      expect(DataSourceConfig.source_for(tenant, "payment_reconciliation")).to be_nil
    end

    it "does not overwrite a data_type the tenant already repointed elsewhere" do
      DataSourceConfig.ensure_default!(tenant, "freight", "pagarme")
      stub_auth

      post "/api/v1/integrations/idworks/connect", headers: auth_headers(admin),
        params: { credentials: { base_url: "https://cliente.idworks.com.br/api/v1", api_key: "tok" } }

      expect(DataSourceConfig.source_for(tenant, "freight")).to eq("pagarme") # untouched
      expect(DataSourceConfig.source_for(tenant, "cost")).to eq("idworks")    # still seeded
    end

    it "marks the integration errored on auth failure but still saves the credentials" do
      stub_auth(status: 401)

      post "/api/v1/integrations/idworks/connect", headers: auth_headers(admin),
        params: { credentials: { base_url: "https://cliente.idworks.com.br/api/v1", api_key: "bad" } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(tenant.integrations.find_by(provider: "idworks").status).to eq("error")
    end
  end

  describe "POST /api/v1/integrations/idworks/sync" do
    it "rejects when idworks isn't connected yet" do
      post "/api/v1/integrations/idworks/sync", headers: auth_headers(admin)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "runs both the product cost sync and invoice sync" do
      tenant.products.create!(sku: "CAM-001-P-AZUL", name: "Camiseta", cost_price: 0)
      tenant.products.create!(sku: "CAN-001", name: "Caneca", cost_price: 0)
      tenant.integrations.create!(
        provider: "idworks", name: "idworks", status: "connected",
        credentials: { base_url: "https://cliente.idworks.com.br/api/v1", api_key: "tok" }
      )
      DataSourceConfig.ensure_defaults_for_source!(tenant, "idworks")
      stub_auth
      stub_request(:get, "https://cliente.idworks.com.br/api/v1/invoices")
        .to_return(status: 200, body: { data: nil }.to_json, headers: { "Content-Type" => "application/json" })

      post "/api/v1/integrations/idworks/sync", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["success"]).to eq(true)
      expect(body["products_synced_count"]).to eq(2)
      expect(body["invoices_synced_count"]).to eq(0)
    end
  end
end
