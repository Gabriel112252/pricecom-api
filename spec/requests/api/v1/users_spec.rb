require "rails_helper"

RSpec.describe "Users", type: :request do
  let(:tenant)   { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:admin)    { tenant.users.create!(name: "Admin", email: "admin@#{SecureRandom.hex(4)}.com", password: "password123", role: "admin") }
  let(:operador) { tenant.users.create!(name: "Operador", email: "op@#{SecureRandom.hex(4)}.com", password: "password123", role: "operador") }

  def auth_headers(user)
    { "Authorization" => "Bearer #{JsonWebToken.encode(user_id: user.id)}" }
  end

  describe "GET /api/v1/users" do
    it "requires admin" do
      get "/api/v1/users", headers: auth_headers(operador)
      expect(response).to have_http_status(:forbidden)
    end

    it "lists only the current tenant's users" do
      admin
      other_tenant = Tenant.create!(name: "Outra Loja", slug: "outra-loja-#{SecureRandom.hex(4)}")
      other_tenant.users.create!(name: "Fora", email: "fora@#{SecureRandom.hex(4)}.com", password: "password123")

      get "/api/v1/users", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      emails = JSON.parse(response.body).map { |u| u["email"] }
      expect(emails).to contain_exactly(admin.email)
    end

    it "never exposes password_digest, invitation_token or mcp_api_key" do
      admin
      get "/api/v1/users", headers: auth_headers(admin)
      expect(response.body).not_to include("password_digest")
      expect(response.body).not_to include("invitation_token")
      expect(response.body).not_to include("mcp_api_key")
      expect(response.body).not_to include(admin.mcp_api_key)
    end
  end

  describe "POST /api/v1/users — cadastro direto" do
    it "requires admin" do
      post "/api/v1/users", params: { name: "Nova", email: "nova@x.com", password: "password123" }, headers: auth_headers(operador)
      expect(response).to have_http_status(:forbidden)
    end

    it "creates an active user with the given password" do
      post "/api/v1/users",
        params: { name: "Nova", email: "nova@#{SecureRandom.hex(4)}.com", password: "password123", role: "operador" },
        headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["active"]).to eq(true)
      expect(body["invitation_pending"]).to eq(false)
      expect(tenant.users.count).to eq(2) # admin + nova
    end

    it "rejects an invalid role" do
      post "/api/v1/users",
        params: { name: "Nova", email: "nova@#{SecureRandom.hex(4)}.com", password: "password123", role: "superadmin" },
        headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "rejects without a password" do
      post "/api/v1/users",
        params: { name: "Nova", email: "nova@#{SecureRandom.hex(4)}.com" },
        headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["errors"]).to be_present
    end

    it "logs user.created" do
      expect {
        post "/api/v1/users",
          params: { name: "Nova", email: "nova@#{SecureRandom.hex(4)}.com", password: "password123" },
          headers: auth_headers(admin)
      }.to change(UserActivityLog, :count).by(1)

      expect(UserActivityLog.last.action).to eq("user.created")
    end
  end

  describe "POST /api/v1/users — convite" do
    it "creates an inactive user with no password, generates a token, and does not blow up even without SMTP configured" do
      expect(ENV["SMTP_ADDRESS"]).to be_blank # ambiente de teste — confirma o cenário que o mailer precisa tolerar

      expect {
        post "/api/v1/users",
          params: { name: "Convidada", email: "convidada@#{SecureRandom.hex(4)}.com", role: "operador", invite: true },
          headers: auth_headers(admin)
      }.not_to raise_error

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["active"]).to eq(false)
      expect(body["invitation_pending"]).to eq(true)

      user = User.find(body["id"])
      expect(user.password_digest).to be_nil
      expect(user.invitation_token).to be_present
    end
  end

  describe "PATCH /api/v1/users/:id" do
    it "requires admin" do
      target = tenant.users.create!(name: "Alvo", email: "alvo@#{SecureRandom.hex(4)}.com", password: "password123")
      patch "/api/v1/users/#{target.id}", params: { role: "admin" }, headers: auth_headers(operador)
      expect(response).to have_http_status(:forbidden)
    end

    it "updates the role and logs user.role_changed" do
      target = tenant.users.create!(name: "Alvo", email: "alvo@#{SecureRandom.hex(4)}.com", password: "password123", role: "operador")

      patch "/api/v1/users/#{target.id}", params: { role: "admin" }, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(target.reload.role).to eq("admin")
      expect(UserActivityLog.where(action: "user.role_changed").last.metadata).to eq("from" => "operador", "to" => "admin")
    end

    it "rejects an invalid role" do
      target = tenant.users.create!(name: "Alvo", email: "alvo@#{SecureRandom.hex(4)}.com", password: "password123")
      patch "/api/v1/users/#{target.id}", params: { role: "god" }, headers: auth_headers(admin)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "reactivates a deactivated user via active=true" do
      target = tenant.users.create!(name: "Alvo", email: "alvo@#{SecureRandom.hex(4)}.com", password: "password123", active: false)
      patch "/api/v1/users/#{target.id}", params: { active: "true" }, headers: auth_headers(admin)
      expect(response).to have_http_status(:ok)
      expect(target.reload.active).to eq(true)
    end

    it "does not leak another tenant's user" do
      other_tenant = Tenant.create!(name: "Outra Loja", slug: "outra-loja-#{SecureRandom.hex(4)}")
      outsider = other_tenant.users.create!(name: "Fora", email: "fora@#{SecureRandom.hex(4)}.com", password: "password123")

      patch "/api/v1/users/#{outsider.id}", params: { role: "admin" }, headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
    end

    # Cuidado geral pedido explicitamente: admin não pode se auto-desativar
    # (evita lockout). Testado tanto via PATCH active=false quanto via
    # DELETE (#destroy) abaixo.
    it "blocks an admin from deactivating themselves via active=false" do
      patch "/api/v1/users/#{admin.id}", params: { active: "false" }, headers: auth_headers(admin)

      expect(response).to have_http_status(:forbidden)
      expect(admin.reload.active).to eq(true)
    end

    it "allows an admin to reactivate their own account (only the false direction is blocked)" do
      admin.update!(active: false)
      patch "/api/v1/users/#{admin.id}", params: { active: "true" }, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
    end
  end

  describe "DELETE /api/v1/users/:id — desativação (não deleta)" do
    it "requires admin" do
      target = tenant.users.create!(name: "Alvo", email: "alvo@#{SecureRandom.hex(4)}.com", password: "password123")
      delete "/api/v1/users/#{target.id}", headers: auth_headers(operador)
      expect(response).to have_http_status(:forbidden)
    end

    it "deactivates instead of deleting, preserving the row" do
      target = tenant.users.create!(name: "Alvo", email: "alvo@#{SecureRandom.hex(4)}.com", password: "password123")
      headers = auth_headers(admin) # força a criação do admin (let) antes do bloco medido abaixo

      expect {
        delete "/api/v1/users/#{target.id}", headers: headers
      }.not_to change(User, :count)

      expect(response).to have_http_status(:ok)
      expect(target.reload.active).to eq(false)
    end

    it "logs user.deactivated" do
      target = tenant.users.create!(name: "Alvo", email: "alvo@#{SecureRandom.hex(4)}.com", password: "password123")
      delete "/api/v1/users/#{target.id}", headers: auth_headers(admin)
      expect(UserActivityLog.where(action: "user.deactivated").last.target_id).to eq(target.id)
    end

    # Cuidado geral pedido explicitamente: admin não pode se auto-desativar.
    it "blocks an admin from deactivating themselves" do
      delete "/api/v1/users/#{admin.id}", headers: auth_headers(admin)

      expect(response).to have_http_status(:forbidden)
      expect(admin.reload.active).to eq(true)
    end

    it "still allows one admin to deactivate a different admin" do
      other_admin = tenant.users.create!(name: "Outro Admin", email: "outro@#{SecureRandom.hex(4)}.com", password: "password123", role: "admin")

      delete "/api/v1/users/#{other_admin.id}", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(other_admin.reload.active).to eq(false)
    end
  end

  describe "POST /api/v1/users/accept_invitation" do
    def invited_user
      user = tenant.users.new(name: "Convidada", email: "convidada@#{SecureRandom.hex(4)}.com")
      user.start_invitation!
      user.save!
      user
    end

    it "does not require authentication" do
      user = invited_user
      post "/api/v1/users/accept_invitation", params: { token: user.invitation_token, password: "novaSenha123" }
      expect(response).to have_http_status(:ok)
    end

    it "sets the password and activates the user" do
      user = invited_user
      post "/api/v1/users/accept_invitation", params: { token: user.invitation_token, password: "novaSenha123" }

      user.reload
      expect(user.active).to eq(true)
      expect(user.invitation_accepted_at).to be_present
      expect(user.authenticate("novaSenha123")).to be_truthy
    end

    it "rejects an invalid token" do
      post "/api/v1/users/accept_invitation", params: { token: "not-a-real-token", password: "novaSenha123" }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    # Cuidado geral pedido explicitamente: token expirado é rejeitado.
    it "rejects an expired token" do
      user = invited_user
      user.update_column(:invitation_sent_at, 8.days.ago)

      post "/api/v1/users/accept_invitation", params: { token: user.invitation_token, password: "novaSenha123" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to match(/expirou/i)
      expect(user.reload.active).to eq(false)
    end

    it "rejects a token that was already used" do
      user = invited_user
      post "/api/v1/users/accept_invitation", params: { token: user.invitation_token, password: "novaSenha123" }
      expect(response).to have_http_status(:ok)

      post "/api/v1/users/accept_invitation", params: { token: user.invitation_token, password: "outraSenha456" }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to match(/já foi utilizado/i)
    end
  end
end
