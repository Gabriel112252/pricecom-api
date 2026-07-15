require "rails_helper"

RSpec.describe "TikTok Shop OAuth callback", type: :request do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:admin) { tenant.users.create!(name: "Admin", email: "admin@#{SecureRandom.hex(4)}.com", password: "password123", role: "admin") }
  let(:token_url) { "https://auth.tiktok-shops.com/api/v2/token/get" }
  let(:state) do
    Rails.application.message_verifier(:tiktok_oauth_state)
      .generate({ tenant_id: tenant.id }, expires_in: 10.minutes)
  end
  let(:token_response) do
    {
      code: 0,
      message: "success",
      data: {
        access_token: "access-token",
        access_token_expire_in: 1_660_556_783,
        refresh_token: "refresh-token",
        refresh_token_expire_in: 1_691_487_031,
        open_id: "open-1",
        seller_name: "Loja TikTok",
        seller_base_region: "BR",
        user_type: 0,
        granted_scopes: [ "product.read" ]
      },
      request_id: "req-1"
    }.to_json
  end

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("FRONTEND_URL", "http://localhost:5173").and_return("https://pricecom-web.example")
  end

  def auth_headers(user)
    { "Authorization" => "Bearer #{JsonWebToken.encode(user_id: user.id)}" }
  end

  def create_tiktok_credential(credentials = { "app_key" => "tenant-app-key", "app_secret" => "tenant-app-secret" })
    tenant.channel_credentials.create!(
      channel: "tiktok",
      status: "pending",
      credentials: credentials
    )
  end

  it "returns the TikTok authorization URL with signed tenant state" do
    create_tiktok_credential

    get "/api/v1/integrations/tiktok/authorize_url", headers: auth_headers(admin)

    expect(response).to have_http_status(:ok)

    uri = URI.parse(JSON.parse(response.body).fetch("authorize_url"))
    query = Rack::Utils.parse_query(uri.query)

    expect("#{uri.scheme}://#{uri.host}#{uri.path}").to eq("https://auth.tiktok-shops.com/oauth/authorize")
    expect(query["app_key"]).to eq("tenant-app-key")
    expect(query["redirect_uri"]).to eq("https://www.example.com/api/v1/webhooks/tiktok")

    signed_state = Rails.application.message_verifier(:tiktok_oauth_state).verify(query.fetch("state"))
    expect(signed_state[:tenant_id] || signed_state["tenant_id"]).to eq(tenant.id)
  end

  it "rejects authorization URL generation before tenant TikTok credentials are saved" do
    get "/api/v1/integrations/tiktok/authorize_url", headers: auth_headers(admin)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)["error"]).to eq("Cadastre App Key e App Secret antes de autorizar")
  end

  it "exchanges code for tokens, saves the TikTok ChannelCredential and redirects to frontend" do
    create_tiktok_credential

    stub_request(:get, token_url)
      .with(query: {
        "app_key" => "tenant-app-key",
        "app_secret" => "tenant-app-secret",
        "auth_code" => "auth-code",
        "grant_type" => "authorized_code"
      })
      .to_return(status: 200, body: token_response, headers: { "Content-Type" => "application/json" })

    get "/api/v1/webhooks/tiktok", params: {
      app_key: "tenant-app-key",
      code: "auth-code",
      state: state,
      locale: "pt-BR",
      shop_region: "BR"
    }

    expect(response).to redirect_to(/https:\/\/pricecom-web\.example\/integracoes\?/)
    expect(response.location).to include("tiktok=connected")

    credential = tenant.channel_credentials.find_by!(channel: "tiktok")
    expect(credential.status).to eq("active")
    expect(credential.credentials).to include(
      "app_key" => "tenant-app-key",
      "app_secret" => "tenant-app-secret",
      "access_token" => "access-token",
      "refresh_token" => "refresh-token",
      "open_id" => "open-1",
      "seller_name" => "Loja TikTok",
      "seller_base_region" => "BR",
      "shop_region" => "BR",
      "locale" => "pt-BR"
    )
    expect(tenant.channels.find_by(platform: "tiktok")).to be_present
  end

  it "redirects with error when TikTok returns code different from zero" do
    credential = create_tiktok_credential

    stub_request(:get, token_url)
      .with(query: hash_including(
        "app_key" => "tenant-app-key",
        "app_secret" => "tenant-app-secret",
        "auth_code" => "expired-code"
      ))
      .to_return(
        status: 200,
        body: { code: 105_001, message: "auth code expired", data: nil, request_id: "req-2" }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    get "/api/v1/webhooks/tiktok", params: { app_key: "tenant-app-key", code: "expired-code", state: state }

    expect(response).to redirect_to(/https:\/\/pricecom-web\.example\/integracoes\?/)
    expect(response.location).to include("tiktok=error")
    expect(response.location).to include("auth+code+expired")
    expect(credential.reload.status).to eq("pending")
  end

  it "rejects callback when app_key does not match the tenant credential" do
    create_tiktok_credential

    get "/api/v1/webhooks/tiktok", params: { app_key: "other-app-key", code: "auth-code", state: state }

    expect(response).to redirect_to(/https:\/\/pricecom-web\.example\/integracoes\?/)
    expect(response.location).to include("tiktok=error")
    expect(response.location).to include("App+Key+inv%C3%A1lida")
    expect(WebMock).to have_not_requested(:get, token_url)
  end

  it "redirects with error when auth code is missing and does not call TikTok" do
    get "/api/v1/webhooks/tiktok", params: { app_key: "tenant-app-key", state: state }

    expect(response).to redirect_to(/https:\/\/pricecom-web\.example\/integracoes\?/)
    expect(response.location).to include("tiktok=error")
    expect(WebMock).to have_not_requested(:get, token_url)
  end

  it "redirects with error when tenant cannot be resolved from signed state or tenant_slug" do
    get "/api/v1/webhooks/tiktok", params: { app_key: "tenant-app-key", code: "auth-code" }

    expect(response).to redirect_to(/https:\/\/pricecom-web\.example\/integracoes\?/)
    expect(response.location).to include("tiktok=error")
    expect(response.location).to include("Tenant+n%C3%A3o+identificado")
  end

  it "keeps POST /webhooks/tiktok routed to the generic webhook receiver" do
    tenant.channel_credentials.create!(
      channel: "tiktok",
      status: "active",
      credentials: { "app_key" => "tenant-app-key", "app_secret" => "webhook-secret", "access_token" => "tok" }
    )
    body = { id: 555, event: "order.created" }.to_json
    signature = OpenSSL::HMAC.hexdigest("sha256", "webhook-secret", body)

    post "/api/v1/webhooks/tiktok", params: body,
      headers: {
        "X-Tenant-Slug" => tenant.slug,
        "Content-Type" => "application/json",
        "X-Tts-Signature" => signature
      }

    expect(response).to have_http_status(:accepted)
  end
end
