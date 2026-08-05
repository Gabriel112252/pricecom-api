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

    it "returns has_unread: false for every row when there is no tiktok credential" do
      channel.affiliate_creators.create!(tenant: tenant, creator_open_id: "u1", conversation_id: "conv-1")

      get "/api/v1/affiliates/creators", headers: auth_headers(operador)

      rows = JSON.parse(response.body)["rows"]
      expect(rows.first["has_unread"]).to eq(false)
    end

    it "marks has_unread: true only for the creator whose conversation_id has an unread message, with a single adapter call for the whole page" do
      channel.affiliate_creators.create!(tenant: tenant, creator_open_id: "u1", conversation_id: "conv-1")
      channel.affiliate_creators.create!(tenant: tenant, creator_open_id: "u2", conversation_id: "conv-2")
      channel.affiliate_creators.create!(tenant: tenant, creator_open_id: "u3", conversation_id: nil)
      tenant.channel_credentials.create!(channel: "tiktok", status: "active", credentials: { app_key: "k", app_secret: "s" })
      adapter = instance_double(Integrations::TiktokAdapter)
      allow(Integrations::TiktokAdapter).to receive(:new).and_return(adapter)
      allow(adapter).to receive(:fetch_latest_unread_messages).and_return(
        [
          { "conversation_id" => "conv-1", "unread_message_count" => 2 },
          { "conversation_id" => "conv-2", "unread_message_count" => 0 }
        ]
      )

      get "/api/v1/affiliates/creators", headers: auth_headers(operador)

      rows = JSON.parse(response.body)["rows"].index_by { |r| r["creator_open_id"] }
      expect(rows["u1"]["has_unread"]).to eq(true)
      expect(rows["u2"]["has_unread"]).to eq(false)
      expect(rows["u3"]["has_unread"]).to eq(false)
      expect(adapter).to have_received(:fetch_latest_unread_messages).once
    end

    it "degrades gracefully (has_unread: false, still 200) when the unread check raises" do
      channel.affiliate_creators.create!(tenant: tenant, creator_open_id: "u1", conversation_id: "conv-1")
      tenant.channel_credentials.create!(channel: "tiktok", status: "active", credentials: { app_key: "k", app_secret: "s" })
      adapter = instance_double(Integrations::TiktokAdapter)
      allow(Integrations::TiktokAdapter).to receive(:new).and_return(adapter)
      allow(adapter).to receive(:fetch_latest_unread_messages).and_raise(Integrations::RateLimitError.new("rate limited"))

      get "/api/v1/affiliates/creators", headers: auth_headers(operador)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["rows"].first["has_unread"]).to eq(false)
    end

    it "does not call the adapter at all when the page has no rows" do
      tenant.channel_credentials.create!(channel: "tiktok", status: "active", credentials: { app_key: "k", app_secret: "s" })
      adapter = instance_double(Integrations::TiktokAdapter)
      allow(Integrations::TiktokAdapter).to receive(:new).and_return(adapter)
      allow(adapter).to receive(:fetch_latest_unread_messages)

      get "/api/v1/affiliates/creators", headers: auth_headers(operador)

      expect(JSON.parse(response.body)["rows"]).to eq([])
      expect(adapter).not_to have_received(:fetch_latest_unread_messages)
    end
  end

  describe "GET /api/v1/affiliates/creators/:id/messages" do
    it "syncs and returns the persisted message history" do
      creator = channel.affiliate_creators.create!(tenant: tenant, creator_open_id: "u1", conversation_id: "conv-1")
      adapter = instance_double(
        Integrations::TiktokAdapter,
        fetch_conversation_messages: { "has_more" => false, "next_page_token" => "", "messages" => [] }
      )
      allow(Integrations::TiktokAdapter).to receive(:new).and_return(adapter)
      tenant.channel_credentials.create!(channel: "tiktok", status: "active", credentials: { app_key: "k", app_secret: "s" })
      creator.affiliate_messages.create!(direction: "inbound", content: "oi", sent_at: Time.current)

      get "/api/v1/affiliates/creators/#{creator.id}/messages", headers: auth_headers(operador)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["sync_failed"]).to eq(false)
      expect(body["rows"].size).to eq(1)
      expect(body["rows"].first["content"]).to eq("oi")
    end

    it "still returns already-persisted messages and flags sync_failed when the live sync fails" do
      creator = channel.affiliate_creators.create!(tenant: tenant, creator_open_id: "u1", conversation_id: "conv-1")
      adapter = instance_double(Integrations::TiktokAdapter)
      allow(Integrations::TiktokAdapter).to receive(:new).and_return(adapter)
      allow(adapter).to receive(:fetch_conversation_messages).and_raise(Integrations::RateLimitError.new("rate limited"))
      tenant.channel_credentials.create!(channel: "tiktok", status: "active", credentials: { app_key: "k", app_secret: "s" })
      creator.affiliate_messages.create!(direction: "outbound", content: "já salva", sent_at: Time.current)

      get "/api/v1/affiliates/creators/#{creator.id}/messages", headers: auth_headers(operador)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["sync_failed"]).to eq(true)
      expect(body["rows"].size).to eq(1)
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
