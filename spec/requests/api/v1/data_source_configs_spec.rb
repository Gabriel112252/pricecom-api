require "rails_helper"

RSpec.describe "Data Source Configs", type: :request do
  let(:tenant)   { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:admin)    { tenant.users.create!(name: "Admin", email: "admin@#{SecureRandom.hex(4)}.com", password: "password123", role: "admin") }
  let(:operador) { tenant.users.create!(name: "Operador", email: "op@#{SecureRandom.hex(4)}.com", password: "password123", role: "operador") }

  def auth_headers(user)
    { "Authorization" => "Bearer #{JsonWebToken.encode(user_id: user.id)}" }
  end

  describe "GET /api/v1/data_source_configs" do
    it "returns all 4 data types even with no config rows yet" do
      get "/api/v1/data_source_configs", headers: auth_headers(operador)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body.map { |c| c["data_type"] }).to contain_exactly("cost", "freight", "tax", "payment_reconciliation")
      expect(body.all? { |c| c["source"].nil? }).to eq(true)
    end

    it "reflects configured sources" do
      DataSourceConfig.ensure_default!(tenant, "cost", "idworks")

      get "/api/v1/data_source_configs", headers: auth_headers(admin)

      cost = JSON.parse(response.body).find { |c| c["data_type"] == "cost" }
      expect(cost["source"]).to eq("idworks")
    end
  end

  describe "PATCH /api/v1/data_source_configs/:data_type" do
    it "requires admin" do
      patch "/api/v1/data_source_configs/freight", params: { source: "pagarme" }, headers: auth_headers(operador)
      expect(response).to have_http_status(:forbidden)
    end

    it "changes the source for a data_type" do
      DataSourceConfig.ensure_default!(tenant, "freight", "idworks")

      patch "/api/v1/data_source_configs/freight", params: { source: "pagarme" }, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(DataSourceConfig.source_for(tenant, "freight")).to eq("pagarme")
    end

    it "creates the config row if one didn't exist yet" do
      patch "/api/v1/data_source_configs/tax", params: { source: "idworks" }, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(DataSourceConfig.source_for(tenant, "tax")).to eq("idworks")
    end

    it "rejects an unknown data_type" do
      patch "/api/v1/data_source_configs/bogus", params: { source: "idworks" }, headers: auth_headers(admin)
      expect(response).to have_http_status(:not_found)
    end

    it "rejects an unknown source" do
      patch "/api/v1/data_source_configs/tax", params: { source: "bogus" }, headers: auth_headers(admin)
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
