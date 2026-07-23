require "rails_helper"

RSpec.describe "Shopee OAuth callback", type: :request do
  let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:admin) { tenant.users.create!(name: "Admin", email: "admin@#{SecureRandom.hex(4)}.com", password: "password123", role: "admin") }
  let(:token_url) { "https://partner.shopeemobile.com/api/v2/auth/token/get" }
  let(:state) do
    Rails.application.message_verifier(:shopee_oauth_state)
      .generate({ tenant_id: tenant.id }, expires_in: 10.minutes)
  end
  let(:token_response) do
    {
      error: "",
      message: "",
      request_id: "req-1",
      access_token: "sp-access-token",
      refresh_token: "sp-refresh-token",
      expire_in: 14_400
    }.to_json
  end

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("FRONTEND_URL", anything).and_return("https://pricecom-web.example")
  end

  def auth_headers(user)
    { "Authorization" => "Bearer #{JsonWebToken.encode(user_id: user.id)}" }
  end

  def create_shopee_credential(credentials = { "partner_id" => "2011234", "partner_key" => "partner-secret" })
    tenant.channel_credentials.create!(
      channel: "shopee",
      status: "pending",
      credentials: credentials
    )
  end

  def stub_token_exchange(body = token_response)
    stub_request(:post, token_url)
      .with(query: hash_including("partner_id" => "2011234", "sign" => /\h{64}/, "timestamp" => /\d+/))
      .to_return(status: 200, body: body, headers: { "Content-Type" => "application/json" })
  end

  it "returns the Shopee authorization URL with signed tenant state inside the redirect" do
    create_shopee_credential

    get "/api/v1/integrations/shopee/authorize_url", headers: auth_headers(admin)

    expect(response).to have_http_status(:ok)

    uri = URI.parse(JSON.parse(response.body).fetch("authorize_url"))
    query = Rack::Utils.parse_query(uri.query)

    expect("#{uri.scheme}://#{uri.host}#{uri.path}").to eq("https://partner.shopeemobile.com/api/v2/shop/auth_partner")
    expect(query["partner_id"]).to eq("2011234")
    expect(query["sign"]).to match(/\A\h{64}\z/)

    redirect_uri = URI.parse(query.fetch("redirect"))
    expect("#{redirect_uri.scheme}://#{redirect_uri.host}#{redirect_uri.path}").to eq("https://www.example.com/api/v1/webhooks/shopee")

    embedded_state = Rack::Utils.parse_query(redirect_uri.query).fetch("state")
    verified = Rails.application.message_verifier(:shopee_oauth_state).verify(embedded_state)
    expect(verified[:tenant_id] || verified["tenant_id"]).to eq(tenant.id)
  end

  it "rejects authorization URL generation before partner credentials are saved" do
    get "/api/v1/integrations/shopee/authorize_url", headers: auth_headers(admin)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)["error"]).to eq("Cadastre Partner ID e Partner Key antes de autorizar")
  end

  it "exchanges code for tokens, saves the Shopee ChannelCredential and redirects to frontend" do
    create_shopee_credential
    stub_token_exchange

    get "/api/v1/webhooks/shopee", params: { code: "auth-code", shop_id: "9001", state: state }

    expect(response).to redirect_to(/https:\/\/pricecom-web\.example\/integracoes\?/)
    expect(response.location).to include("shopee=connected")

    credential = tenant.channel_credentials.find_by!(channel: "shopee")
    expect(credential.status).to eq("active")
    expect(credential.credentials).to include(
      "partner_id" => "2011234",
      "partner_key" => "partner-secret",
      "shop_id" => "9001",
      "access_token" => "sp-access-token",
      "refresh_token" => "sp-refresh-token"
    )
    expect(Time.zone.parse(credential.credentials.fetch("token_expires_at"))).to be_within(1.minute).of(4.hours.from_now)
    expect(tenant.channels.find_by(platform: "shopee")).to be_present
  end

  it "redirects with error when Shopee rejects the code" do
    credential = create_shopee_credential
    stub_token_exchange({ error: "error_auth", message: "Invalid code" }.to_json)

    get "/api/v1/webhooks/shopee", params: { code: "expired-code", shop_id: "9001", state: state }

    expect(response.location).to include("shopee=error")
    expect(response.location).to include("Invalid+code")
    expect(credential.reload.status).to eq("pending")
  end

  it "redirects with error when code is missing and does not call Shopee" do
    create_shopee_credential

    get "/api/v1/webhooks/shopee", params: { shop_id: "9001", state: state }

    expect(response.location).to include("shopee=error")
    expect(WebMock).to have_not_requested(:post, token_url)
  end

  it "redirects with error when shop_id is missing (main account flow)" do
    create_shopee_credential

    get "/api/v1/webhooks/shopee", params: { code: "auth-code", state: state }

    expect(response.location).to include("shopee=error")
    expect(response.location).to include("shop_id")
    expect(WebMock).to have_not_requested(:post, token_url)
  end

  it "redirects with error when tenant cannot be resolved from signed state" do
    create_shopee_credential

    get "/api/v1/webhooks/shopee", params: { code: "auth-code", shop_id: "9001" }

    expect(response.location).to include("shopee=error")
    expect(response.location).to include("Tenant+n%C3%A3o+identificado")
    expect(WebMock).to have_not_requested(:post, token_url)
  end
end
