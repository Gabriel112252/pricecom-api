require "rails_helper"

RSpec.describe "Channel Credentials", type: :request do
  let(:tenant)   { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:admin)    { tenant.users.create!(name: "Admin", email: "admin@#{SecureRandom.hex(4)}.com", password: "password123", role: "admin") }
  let(:operador) { tenant.users.create!(name: "Operador", email: "op@#{SecureRandom.hex(4)}.com", password: "password123", role: "operador") }
  let(:orders_fixture) { File.read(Rails.root.join("spec/fixtures/integrations/yampi_orders.json")) }

  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    example.run
  ensure
    ActiveJob::Base.queue_adapter = original_adapter
  end

  def auth_headers(user)
    { "Authorization" => "Bearer #{JsonWebToken.encode(user_id: user.id)}" }
  end

  describe "POST /api/v1/integrations/yampi/backfill_orders" do
    it "requires admin" do
      tenant.channels.create!(name: "Yampi", platform: "yampi")
      tenant.channel_credentials.create!(channel: "yampi", status: "active", credentials: { alias: "loja", token: "t", secret_key: "s", webhook_secret: "wh" })

      post "/api/v1/integrations/yampi/backfill_orders", headers: auth_headers(operador)

      expect(response).to have_http_status(:forbidden)
    end

    it "rejects when Yampi isn't connected yet" do
      post "/api/v1/integrations/yampi/backfill_orders", headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to eq("Yampi ainda não está conectada")
    end

    it "enqueues the polling job and returns 202 without importing inline" do
      tenant.channels.create!(name: "Yampi", platform: "yampi")
      tenant.channel_credentials.create!(channel: "yampi", status: "active", credentials: { alias: "loja", token: "t", secret_key: "s", webhook_secret: "wh" })

      post "/api/v1/integrations/yampi/backfill_orders", params: { days: 30 }, headers: auth_headers(admin)

      expect(response).to have_http_status(:accepted)
      body = JSON.parse(response.body)
      expect(body["success"]).to eq(true)
      expect(body["enqueued"]).to eq(true)
      expect(tenant.orders.count).to eq(0)
      expect(ActiveJob::Base.queue_adapter.enqueued_jobs.size).to eq(1)
    end

    it "enqueues the same polling job when days is omitted" do
      tenant.channels.create!(name: "Yampi", platform: "yampi")
      tenant.channel_credentials.create!(channel: "yampi", status: "active", credentials: { alias: "loja", token: "t", secret_key: "s", webhook_secret: "wh" })

      post "/api/v1/integrations/yampi/backfill_orders", headers: auth_headers(admin)

      expect(response).to have_http_status(:accepted)
      expect(ActiveJob::Base.queue_adapter.enqueued_jobs.size).to eq(1)
    end
  end

  # Regression: connecting a channel (creating/updating a ChannelCredential)
  # used to leave the older `channels` table untouched, so Order#channel_id
  # had nothing to resolve to — order ingestion (webhook/backfill) failed
  # with "Canal não encontrado para provider 'yampi'" for 2290 real orders
  # even though Yampi was connected and syncing products normally. See
  # Channel.ensure_for! and ChannelCredentialsController#connect.
  describe "POST /api/v1/integrations/:channel/connect" do
    def stub_yampi_auth
      stub_request(:get, "https://api.dooki.com.br/v2/loja/catalog/products")
        .with(query: hash_including("page" => "1", "per_page" => "1"))
        .to_return(status: 200, body: { data: [] }.to_json, headers: { "Content-Type" => "application/json" })
    end

    it "lists TikTok setup fields without manual access token" do
      get "/api/v1/integrations/channels", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      tiktok = JSON.parse(response.body).find { |channel| channel["channel"] == "tiktok" }

      expect(tiktok["required_fields"]).to eq(%w[app_key app_secret])
      expect(tiktok["credentials_configured"]).to eq(false)
    end

    it "stores TikTok App Key and App Secret as pending without authenticating before OAuth" do
      post "/api/v1/integrations/tiktok/connect", headers: auth_headers(admin),
        params: { credentials: { app_key: "tenant-app-key", app_secret: "tenant-app-secret" } }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["status"]).to eq("pending")
      expect(body["required_fields"]).to eq(%w[app_key app_secret])
      expect(body["credentials_configured"]).to eq(true)

      credential = tenant.channel_credentials.find_by!(channel: "tiktok")
      expect(credential.status).to eq("pending")
      expect(credential.credentials).to include(
        "app_key" => "tenant-app-key",
        "app_secret" => "tenant-app-secret"
      )
      expect(credential.credentials).not_to have_key("access_token")
      expect(tenant.channels.find_by(platform: "tiktok")).to be_present
    end

    it "creates the matching Channel the first time a new channel is connected" do
      stub_yampi_auth
      expect(tenant.channels.where(platform: "yampi")).to be_empty

      post "/api/v1/integrations/yampi/connect", headers: auth_headers(admin),
        params: { credentials: { alias: "loja", token: "t", secret_key: "s", webhook_secret: "wh" } }

      expect(response).to have_http_status(:ok)
      channel = tenant.channels.find_by(platform: "yampi")
      expect(channel).to be_present
      expect(channel.name).to eq("Yampi")
    end

    it "does not duplicate the Channel when one already exists (e.g. created manually, or from a prior connect)" do
      existing = tenant.channels.create!(name: "Yampi (Loja Principal)", platform: "yampi")
      stub_yampi_auth

      post "/api/v1/integrations/yampi/connect", headers: auth_headers(admin),
        params: { credentials: { alias: "loja", token: "t", secret_key: "s", webhook_secret: "wh" } }

      expect(response).to have_http_status(:ok)
      expect(tenant.channels.where(platform: "yampi").count).to eq(1)
      expect(tenant.channels.find_by(platform: "yampi")).to eq(existing) # unchanged, not replaced
    end

    it "still creates the Channel even when re-connecting fails authentication" do
      stub_request(:get, "https://api.dooki.com.br/v2/loja/catalog/products")
        .with(query: hash_including("page" => "1"))
        .to_return(status: 401, body: { message: "Unauthenticated" }.to_json)

      post "/api/v1/integrations/yampi/connect", headers: auth_headers(admin),
        params: { credentials: { alias: "loja", token: "bad", secret_key: "s", webhook_secret: "wh" } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(tenant.channels.find_by(platform: "yampi")).to be_present
    end
  end

  describe "POST /api/v1/integrations/:channel/sync" do
    it "rejects product synchronization for lucrofrete" do
      tenant.channel_credentials.create!(
        channel: "lucrofrete",
        status: "active",
        credentials: { email: "frete@example.com", password: "password" }
      )
      expect(Integrations::ProductSyncService).not_to receive(:call)

      post "/api/v1/integrations/lucrofrete/sync", headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to eq(
        "Sincronização de produtos não suportada para o canal lucrofrete"
      )
    end
  end
end
