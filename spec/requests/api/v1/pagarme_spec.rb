require "rails_helper"

RSpec.describe "Pagar.me integration", type: :request do
  let(:tenant)   { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:admin)    { tenant.users.create!(name: "Admin", email: "admin@#{SecureRandom.hex(4)}.com", password: "password123", role: "admin") }
  let(:operador) { tenant.users.create!(name: "Operador", email: "op@#{SecureRandom.hex(4)}.com", password: "password123", role: "operador") }
  let(:orders_fixture) { File.read(Rails.root.join("spec/fixtures/integrations/pagarme_orders.json")) }

  def auth_headers(user)
    { "Authorization" => "Bearer #{JsonWebToken.encode(user_id: user.id)}" }
  end

  def stub_auth(status: 200)
    stub_request(:get, "https://api.pagar.me/core/v5/orders")
      .with(query: hash_including("page" => "1"))
      .to_return(status: status, body: status == 200 ? orders_fixture : { message: "Unauthorized" }.to_json,
                 headers: { "Content-Type" => "application/json" })
  end

  describe "POST /api/v1/integrations/pagarme/connect" do
    it "requires admin" do
      post "/api/v1/integrations/pagarme/connect", headers: auth_headers(operador)
      expect(response).to have_http_status(:forbidden)
    end

    it "creates the FinancialSource and seeds payment_reconciliation -> pagarme" do
      stub_auth

      post "/api/v1/integrations/pagarme/connect", headers: auth_headers(admin),
        params: { credentials: { api_key: "sk_test_abc123" } }

      expect(response).to have_http_status(:ok)
      source = tenant.financial_sources.find_by(provider: "pagarme")
      expect(source.status).to eq("active")
      expect(source.source_type).to eq("gateway")
      expect(DataSourceConfig.source_for(tenant, "payment_reconciliation")).to eq("pagarme")
    end

    it "does not duplicate the FinancialSource on a second connect (credential rotation)" do
      stub_auth
      post "/api/v1/integrations/pagarme/connect", headers: auth_headers(admin), params: { credentials: { api_key: "sk_test_abc123" } }
      post "/api/v1/integrations/pagarme/connect", headers: auth_headers(admin), params: { credentials: { api_key: "sk_test_new" } }

      expect(tenant.financial_sources.where(provider: "pagarme").count).to eq(1)
    end

    it "marks the source errored on auth failure" do
      stub_auth(status: 401)

      post "/api/v1/integrations/pagarme/connect", headers: auth_headers(admin), params: { credentials: { api_key: "bad" } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(tenant.financial_sources.find_by(provider: "pagarme").status).to eq("error")
    end
  end

  describe "POST /api/v1/integrations/pagarme/sync" do
    it "rejects when Pagar.me isn't connected yet" do
      post "/api/v1/integrations/pagarme/sync", headers: auth_headers(admin)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "runs the settlement sync and returns created/updated/skipped counts" do
      tenant.channels.create!(name: "Yampi", platform: "yampi")
      tenant.financial_sources.create!(provider: "pagarme", name: "Pagar.me", source_type: "gateway", status: "active", credentials: { api_key: "sk_test_abc123" })
      stub_auth

      post "/api/v1/integrations/pagarme/sync", params: { days: 30 }, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["success"]).to eq(true)
      expect(body["created_count"]).to eq(1)
      expect(body["skipped_count"]).to eq(1)
    end
  end
end
