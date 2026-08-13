require "rails_helper"

RSpec.describe "Auth", type: :request do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:user) do
    tenant.users.create!(name: "Ana", email: "ana@#{SecureRandom.hex(4)}.com", password: "password123", role: "operador")
  end

  describe "POST /api/v1/auth/login" do
    it "logs in with valid credentials and records login.success" do
      post "/api/v1/auth/login", params: { email: user.email, password: "password123" }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["token"]).to be_present
      expect(body["user"]["email"]).to eq(user.email)

      log = UserActivityLog.last
      expect(log.action).to eq("login.success")
      expect(log.user_id).to eq(user.id)
      expect(log.tenant_id).to eq(tenant.id)
    end

    it "rejects an invalid password and records login.failed" do
      post "/api/v1/auth/login", params: { email: user.email, password: "wrong" }

      expect(response).to have_http_status(:unauthorized)

      log = UserActivityLog.last
      expect(log.action).to eq("login.failed")
      expect(log.user_id).to eq(user.id)
      expect(log.metadata["reason"]).to eq("wrong_password")
    end

    # Garantia explícita pedida: usuário desativado não consegue logar —
    # já era o comportamento do controller antes desta feature
    # (user.active? checado em #login), continua valendo depois de
    # adicionar convite/password_digest nullable.
    it "rejects a deactivated user even with the correct password" do
      user.update!(active: false)

      post "/api/v1/auth/login", params: { email: user.email, password: "password123" }

      expect(response).to have_http_status(:unauthorized)
      log = UserActivityLog.last
      expect(log.action).to eq("login.failed")
      expect(log.metadata["reason"]).to eq("inactive")
    end

    it "does not blow up (and does not log) for a completely unknown email" do
      expect {
        post "/api/v1/auth/login", params: { email: "ninguem@nada.com", password: "x" }
      }.not_to change(UserActivityLog, :count)

      expect(response).to have_http_status(:unauthorized)
    end

    it "never includes the password in the activity log metadata" do
      post "/api/v1/auth/login", params: { email: user.email, password: "th1s-must-never-be-logged" }

      expect(UserActivityLog.last.metadata.to_s).not_to include("th1s-must-never-be-logged")
    end
  end
end
