require "rails_helper"

RSpec.describe "Channel Credentials", type: :request do
  let(:tenant)   { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:admin)    { tenant.users.create!(name: "Admin", email: "admin@#{SecureRandom.hex(4)}.com", password: "password123", role: "admin") }
  let(:operador) { tenant.users.create!(name: "Operador", email: "op@#{SecureRandom.hex(4)}.com", password: "password123", role: "operador") }
  let(:orders_fixture) { File.read(Rails.root.join("spec/fixtures/integrations/yampi_orders.json")) }

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

    it "runs the backfill and returns created/updated/skipped counts" do
      tenant.channels.create!(name: "Yampi", platform: "yampi")
      tenant.channel_credentials.create!(channel: "yampi", status: "active", credentials: { alias: "loja", token: "t", secret_key: "s", webhook_secret: "wh" })

      stub_request(:get, "https://api.dooki.com.br/v2/loja/catalog/products")
        .with(query: hash_including("page" => "1", "per_page" => "1"))
        .to_return(status: 200, body: { data: [] }.to_json, headers: { "Content-Type" => "application/json" })
      stub_request(:get, "https://api.dooki.com.br/v2/loja/orders")
        .with(query: hash_including("page" => "1"))
        .to_return(status: 200, body: orders_fixture, headers: { "Content-Type" => "application/json" })

      post "/api/v1/integrations/yampi/backfill_orders", params: { days: 30 }, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["success"]).to eq(true)
      expect(body["created_count"]).to eq(2)
      expect(body["updated_count"]).to eq(0)
      expect(body["skipped_count"]).to eq(0)
      expect(tenant.orders.count).to eq(2)
    end

    it "defaults to a 30-day window when days is omitted" do
      tenant.channels.create!(name: "Yampi", platform: "yampi")
      tenant.channel_credentials.create!(channel: "yampi", status: "active", credentials: { alias: "loja", token: "t", secret_key: "s", webhook_secret: "wh" })

      stub_request(:get, "https://api.dooki.com.br/v2/loja/catalog/products")
        .with(query: hash_including("page" => "1", "per_page" => "1"))
        .to_return(status: 200, body: { data: [] }.to_json, headers: { "Content-Type" => "application/json" })
      stub_request(:get, "https://api.dooki.com.br/v2/loja/orders")
        .with(query: hash_including("date" => "created_at:#{30.days.ago.to_date.iso8601}|#{Date.current.iso8601}"))
        .to_return(status: 200, body: orders_fixture, headers: { "Content-Type" => "application/json" })

      post "/api/v1/integrations/yampi/backfill_orders", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
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
end
