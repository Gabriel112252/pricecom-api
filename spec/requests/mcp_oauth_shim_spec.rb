require "rails_helper"

# Shim OAuth-like pra satisfazer o handshake que o conector MCP do
# Claude.ai/Claude Desktop espera antes de aceitar conectar como "App" —
# não é OAuth de verdade (ver comentário em config/initializers/fast_mcp.rb).
# Mesmo padrão do ScrumFlow (~/projetos/scrumflow/back), adaptado.
RSpec.describe "MCP OAuth shim", type: :request do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:user)   { tenant.users.create!(name: "Ana", email: "ana@#{SecureRandom.hex(4)}.com", password: "password123") }

  describe "GET /.well-known/oauth-authorization-server" do
    it "advertises the authorize/token/register endpoints" do
      get "/.well-known/oauth-authorization-server"

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["authorization_endpoint"]).to end_with("/oauth/authorize")
      expect(body["token_endpoint"]).to end_with("/oauth/token")
      expect(body["registration_endpoint"]).to end_with("/register")
    end
  end

  describe "GET /.well-known/oauth-protected-resource" do
    it "points at the /mcp/sse resource" do
      get "/.well-known/oauth-protected-resource"

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["resource"]).to end_with("/mcp/sse")
    end
  end

  describe "POST /register" do
    it "echoes back the redirect_uris the client sent, with a fixed client_id" do
      post "/register", params: { redirect_uris: [ "https://claude.ai/callback" ] }.to_json,
        headers: { "CONTENT_TYPE" => "application/json" }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["client_id"]).to eq("claude-ai")
      expect(body["redirect_uris"]).to eq([ "https://claude.ai/callback" ])
    end
  end

  describe "GET /oauth/authorize" do
    it "redirects to the frontend's consent screen, preserving redirect_uri and state" do
      get "/oauth/authorize", params: { redirect_uri: "https://claude.ai/callback", state: "xyz" }

      expect(response).to have_http_status(:found)
      location = response.headers["Location"]
      expect(location).to include("/configuracoes")
      expect(location).to include(CGI.escape("https://claude.ai/callback"))
      expect(location).to include("state=xyz")
    end
  end

  describe "POST /oauth/token" do
    it "exchanges a valid code (the user's own mcp_api_key) for an access_token" do
      post "/oauth/token", params: { code: user.mcp_api_key }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["access_token"]).to eq(user.mcp_api_key)
      expect(body["token_type"]).to eq("Bearer")
    end

    it "rejects an unknown code" do
      post "/oauth/token", params: { code: "not-a-real-token" }

      expect(response).to have_http_status(:unauthorized)
      expect(JSON.parse(response.body)["error"]).to eq("invalid_grant")
    end
  end
end
