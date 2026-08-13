require "rails_helper"

RSpec.describe "MCP Tokens", type: :request do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:user)   { tenant.users.create!(name: "Ana", email: "ana@#{SecureRandom.hex(4)}.com", password: "password123", role: "operador") }

  def auth_headers(user)
    { "Authorization" => "Bearer #{JsonWebToken.encode(user_id: user.id)}" }
  end

  describe "GET /api/v1/mcp_token" do
    it "confirms a token exists without ever exposing its value" do
      get "/api/v1/mcp_token", headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body).to eq("configured" => true)
      expect(response.body).not_to include(user.mcp_api_key)
    end

    it "is available to any authenticated user, not just admins — token is per-user" do
      get "/api/v1/mcp_token", headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /api/v1/mcp_token" do
    it "regenerates the token and returns the raw value exactly this once" do
      previous_token = user.mcp_api_key

      post "/api/v1/mcp_token", headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["mcp_api_key"]).to be_present
      expect(body["mcp_api_key"]).not_to eq(previous_token)
      expect(user.reload.mcp_api_key).to eq(body["mcp_api_key"])
    end

    it "invalidates the previous token immediately" do
      previous_token = user.mcp_api_key
      post "/api/v1/mcp_token", headers: auth_headers(user)

      expect(User.find_by(mcp_api_key: previous_token)).to be_nil
    end
  end
end
