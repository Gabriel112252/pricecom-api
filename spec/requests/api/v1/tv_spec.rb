require "rails_helper"

RSpec.describe "TV Mode", type: :request do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:admin)    { tenant.users.create!(name: "Admin", email: "admin@#{SecureRandom.hex(4)}.com", password: "password123", role: "admin") }
  let(:operador) { tenant.users.create!(name: "Operador", email: "op@#{SecureRandom.hex(4)}.com", password: "password123", role: "operador") }

  def auth_headers(user)
    { "Authorization" => "Bearer #{JsonWebToken.encode(user_id: user.id)}" }
  end

  describe "GET /api/v1/tv_token" do
    it "returns null when no token has been generated yet" do
      get "/api/v1/tv_token", headers: auth_headers(admin)
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq({ "tv_token" => nil })
    end

    it "returns the current token once generated" do
      post "/api/v1/tv_token", headers: auth_headers(admin)
      token = JSON.parse(response.body)["tv_token"]

      get "/api/v1/tv_token", headers: auth_headers(admin)
      expect(JSON.parse(response.body)["tv_token"]).to eq(token)
    end
  end

  describe "POST /api/v1/tv_token" do
    it "requires admin" do
      post "/api/v1/tv_token", headers: auth_headers(operador)
      expect(response).to have_http_status(:forbidden)
    end

    it "generates a token for an admin and rotates it on repeated calls" do
      post "/api/v1/tv_token", headers: auth_headers(admin)
      expect(response).to have_http_status(:ok)
      first_token = JSON.parse(response.body)["tv_token"]
      expect(first_token).to be_present

      post "/api/v1/tv_token", headers: auth_headers(admin)
      second_token = JSON.parse(response.body)["tv_token"]

      expect(second_token).not_to eq(first_token)
    end
  end

  describe "GET /api/v1/tv/:token/summary" do
    it "serves the dashboard summary with no user session, given a valid token" do
      post "/api/v1/tv_token", headers: auth_headers(admin)
      token = JSON.parse(response.body)["tv_token"]

      get "/api/v1/tv/#{token}/summary"

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to have_key("revenue")
    end

    it "rejects an invalid token without ever exposing tenant data" do
      get "/api/v1/tv/not-a-real-token/summary"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE /api/v1/tv_token" do
    it "revokes the token so the previous link stops working" do
      post "/api/v1/tv_token", headers: auth_headers(admin)
      token = JSON.parse(response.body)["tv_token"]

      delete "/api/v1/tv_token", headers: auth_headers(admin)
      expect(response).to have_http_status(:ok)

      get "/api/v1/tv/#{token}/summary"
      expect(response).to have_http_status(:not_found)
    end
  end
end
