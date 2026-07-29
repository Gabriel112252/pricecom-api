require "rails_helper"

RSpec.describe "Testimonials public token", type: :request do
  let(:tenant)   { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:admin)    { tenant.users.create!(name: "Admin", email: "admin@#{SecureRandom.hex(4)}.com", password: "password123", role: "admin") }
  let(:operador) { tenant.users.create!(name: "Operador", email: "op@#{SecureRandom.hex(4)}.com", password: "password123", role: "operador") }

  def auth_headers(user)
    { "Authorization" => "Bearer #{JsonWebToken.encode(user_id: user.id)}" }
  end

  describe "GET /api/v1/testimonials_public_token" do
    it "returns null when no token has been generated yet" do
      get "/api/v1/testimonials_public_token", headers: auth_headers(admin)
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq({ "testimonials_public_token" => nil })
    end
  end

  describe "POST /api/v1/testimonials_public_token" do
    it "requires admin" do
      post "/api/v1/testimonials_public_token", headers: auth_headers(operador)
      expect(response).to have_http_status(:forbidden)
    end

    it "generates a token for an admin and rotates it on repeated calls" do
      post "/api/v1/testimonials_public_token", headers: auth_headers(admin)
      first_token = JSON.parse(response.body)["testimonials_public_token"]
      expect(first_token).to be_present

      post "/api/v1/testimonials_public_token", headers: auth_headers(admin)
      second_token = JSON.parse(response.body)["testimonials_public_token"]

      expect(second_token).not_to eq(first_token)
    end
  end

  describe "DELETE /api/v1/testimonials_public_token" do
    it "revokes the token so the previous link stops working" do
      post "/api/v1/testimonials_public_token", headers: auth_headers(admin)
      token = JSON.parse(response.body)["testimonials_public_token"]

      delete "/api/v1/testimonials_public_token", headers: auth_headers(admin)
      expect(response).to have_http_status(:ok)

      get "/api/public/v1/testimonials", params: { tenant: token }
      expect(response).to have_http_status(:not_found)
    end
  end
end
