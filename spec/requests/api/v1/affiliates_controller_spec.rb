require "rails_helper"

RSpec.describe "Affiliates", type: :request do
  let(:tenant)       { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:other_tenant) { Tenant.create!(name: "Outra Loja", slug: "outra-loja-#{SecureRandom.hex(4)}") }
  let(:operador)     { tenant.users.create!(name: "Operador", email: "op@#{SecureRandom.hex(4)}.com", password: "password123", role: "operador") }
  let(:channel)      { Channel.ensure_for!(tenant, "tiktok") }

  def auth_headers(user)
    { "Authorization" => "Bearer #{JsonWebToken.encode(user_id: user.id)}" }
  end

  describe "GET /api/v1/affiliates/overview" do
    it "returns supported: false when the tenant has no tiktok channel" do
      get "/api/v1/affiliates/overview", headers: auth_headers(operador)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["supported"]).to eq(false)
    end

    it "returns creator counts scoped to the current tenant only" do
      channel.affiliate_creators.create!(tenant: tenant, creator_open_id: "u1", collaboration_status: "NORMAL")
      other_channel = Channel.ensure_for!(other_tenant, "tiktok")
      other_channel.affiliate_creators.create!(tenant: other_tenant, creator_open_id: "u2", collaboration_status: "NORMAL")

      get "/api/v1/affiliates/overview", headers: auth_headers(operador)

      body = JSON.parse(response.body)
      expect(body["supported"]).to eq(true)
      expect(body["total_creators"]).to eq(1)
    end
  end

  describe "GET /api/v1/affiliates/creators" do
    it "returns only the current tenant's creators, filtered by collaboration_status" do
      channel.affiliate_creators.create!(tenant: tenant, creator_open_id: "u1", collaboration_status: "NORMAL")
      channel.affiliate_creators.create!(tenant: tenant, creator_open_id: "u2", collaboration_status: "PAUSED")

      get "/api/v1/affiliates/creators", params: { collaboration_status: "NORMAL" }, headers: auth_headers(operador)

      rows = JSON.parse(response.body)["rows"]
      expect(rows.size).to eq(1)
      expect(rows.first["creator_open_id"]).to eq("u1")
    end
  end

  describe "POST /api/v1/affiliates/creators/:id/messages" do
    it "sends the message and persists it" do
      creator = channel.affiliate_creators.create!(tenant: tenant, creator_open_id: "u1", conversation_id: "conv-1")
      adapter = instance_double(Integrations::TiktokAdapter, send_message: {})
      allow(Integrations::TiktokAdapter).to receive(:new).and_return(adapter)
      tenant.channel_credentials.create!(channel: "tiktok", status: "active", credentials: { app_key: "k", app_secret: "s" })

      post "/api/v1/affiliates/creators/#{creator.id}/messages", params: { content: "Oi!" }, headers: auth_headers(operador)

      expect(response).to have_http_status(:ok)
      expect(creator.affiliate_messages.count).to eq(1)
    end

    it "returns 404 for a creator belonging to another tenant" do
      other_channel = Channel.ensure_for!(other_tenant, "tiktok")
      creator = other_channel.affiliate_creators.create!(tenant: other_tenant, creator_open_id: "u1")

      post "/api/v1/affiliates/creators/#{creator.id}/messages", params: { content: "Oi!" }, headers: auth_headers(operador)

      expect(response).to have_http_status(:not_found)
    end
  end
end
