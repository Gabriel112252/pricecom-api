require "rails_helper"

# Testa o monkey-patch de app/config/initializers/fast_mcp.rb diretamente
# nos métodos privados da classe reaberta — os dois bugs da gem stock
# (fast-mcp 1.6.0, confirmado lendo o código da gem instalada) que ele
# corrige:
#   1. valid_token? fazia `token == @auth_token` (comparação direta) em vez
#      de chamar o lambda — um auth_token callable nunca autenticava nada.
#   2. Token só era lido do header Authorization, nunca de ?token=.
RSpec.describe "FastMcp auth patch", type: :model do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:user) { tenant.users.create!(name: "Ana", email: "ana@#{SecureRandom.hex(4)}.com", password: "password123") }

  let(:transport) do
    FastMcp::Transports::AuthenticatedRackTransport.new(
      ->(_env) { [200, {}, ["ok"]] },
      double("server"),
      auth_token: ->(token) { User.find_by(mcp_api_key: token) },
      logger: Logger.new(IO::NULL)
    )
  end

  after { Current.reset }

  def build_request(headers: {}, query: "")
    env = Rack::MockRequest.env_for("/mcp/sse?#{query}", headers)
    Rack::Request.new(env)
  end

  describe "#extract_bearer_token" do
    it "reads the token from the Authorization header" do
      request = build_request(headers: { "HTTP_AUTHORIZATION" => "Bearer #{user.mcp_api_key}" })
      expect(transport.send(:extract_bearer_token, request)).to eq(user.mcp_api_key)
    end

    it "falls back to ?token= — needed by the Claude.ai MCP connector, unsupported by the stock gem" do
      request = build_request(query: "token=#{user.mcp_api_key}")
      expect(transport.send(:extract_bearer_token, request)).to eq(user.mcp_api_key)
    end

    it "prefers the header over the query param when both are present" do
      other = tenant.users.create!(name: "Outro", email: "outro@#{SecureRandom.hex(4)}.com", password: "password123")
      request = build_request(
        headers: { "HTTP_AUTHORIZATION" => "Bearer #{user.mcp_api_key}" },
        query: "token=#{other.mcp_api_key}"
      )
      expect(transport.send(:extract_bearer_token, request)).to eq(user.mcp_api_key)
    end
  end

  describe "#valid_token?" do
    it "calls the auth_token lambda (not a plain string ==) and sets Current.user" do
      expect(transport.send(:valid_token?, user.mcp_api_key)).to eq(true)
      expect(Current.user).to eq(user)
    end

    it "returns false for a token that doesn't resolve to any user" do
      expect(transport.send(:valid_token?, "not-a-real-token")).to eq(false)
    end

    it "returns false for a blank token without calling the lambda" do
      expect(transport.send(:valid_token?, "")).to eq(false)
      expect(transport.send(:valid_token?, nil)).to eq(false)
    end
  end
end
