require "rails_helper"

RSpec.describe "User Activity Logs", type: :request do
  let(:tenant)   { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:admin)    { tenant.users.create!(name: "Admin", email: "admin@#{SecureRandom.hex(4)}.com", password: "password123", role: "admin") }
  let(:operador) { tenant.users.create!(name: "Operador", email: "op@#{SecureRandom.hex(4)}.com", password: "password123", role: "operador") }

  def auth_headers(user)
    { "Authorization" => "Bearer #{JsonWebToken.encode(user_id: user.id)}" }
  end

  describe "GET /api/v1/user_activity_logs" do
    it "requires admin" do
      get "/api/v1/user_activity_logs", headers: auth_headers(operador)
      expect(response).to have_http_status(:forbidden)
    end

    it "lists only the current tenant's logs" do
      tenant.user_activity_logs.create!(user: admin, action: "login.success")
      other_tenant = Tenant.create!(name: "Outra Loja", slug: "outra-loja-#{SecureRandom.hex(4)}")
      other_tenant.user_activity_logs.create!(action: "login.success")

      get "/api/v1/user_activity_logs", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["logs"].size).to eq(1)
      expect(body["meta"]["total_count"]).to eq(1)
    end

    it "filters by action_type" do
      tenant.user_activity_logs.create!(user: admin, action: "login.success")
      tenant.user_activity_logs.create!(user: admin, action: "login.failed")

      get "/api/v1/user_activity_logs", params: { action_type: "login.failed" }, headers: auth_headers(admin)

      body = JSON.parse(response.body)
      expect(body["logs"].size).to eq(1)
      expect(body["logs"].first["action"]).to eq("login.failed")
    end

    it "filters by user_id" do
      other = tenant.users.create!(name: "Outro", email: "outro@#{SecureRandom.hex(4)}.com", password: "password123")
      tenant.user_activity_logs.create!(user: admin, action: "login.success")
      tenant.user_activity_logs.create!(user: other, action: "login.success")

      get "/api/v1/user_activity_logs", params: { user_id: other.id }, headers: auth_headers(admin)

      body = JSON.parse(response.body)
      expect(body["logs"].size).to eq(1)
      expect(body["logs"].first["user"]["id"]).to eq(other.id)
    end
  end
end
