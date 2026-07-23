require "rails_helper"

RSpec.describe Integrations::ShopeeAuthService do
  let(:base_credentials) { { "partner_id" => "2011234", "partner_key" => "partner-secret-key" } }
  let(:service) { described_class.new(base_credentials) }
  let(:token_get_url) { "https://partner.shopeemobile.com/api/v2/auth/token/get" }
  let(:refresh_url) { "https://partner.shopeemobile.com/api/v2/auth/access_token/get" }

  describe "#public_sign / #shop_sign" do
    it "signs partner_id + path + timestamp with HMAC-SHA256 keyed by partner_key" do
      timestamp = 1_700_000_000
      expected = OpenSSL::HMAC.hexdigest(
        "SHA256", "partner-secret-key", "2011234/api/v2/auth/token/get#{timestamp}"
      )

      expect(service.public_sign("/api/v2/auth/token/get", timestamp)).to eq(expected)
    end

    it "appends access_token + shop_id on the shop-level variant" do
      timestamp = 1_700_000_000
      expected = OpenSSL::HMAC.hexdigest(
        "SHA256", "partner-secret-key", "2011234/api/v2/order/get_order_list#{timestamp}sp-access9001"
      )

      expect(
        service.shop_sign("/api/v2/order/get_order_list", timestamp, access_token: "sp-access", shop_id: "9001")
      ).to eq(expected)
    end
  end

  describe "#authorize_url" do
    it "builds the auth_partner URL with public sign and the redirect embedded" do
      url = service.authorize_url(redirect_url: "https://api.example.com/api/v1/webhooks/shopee?state=abc")
      uri = URI.parse(url)
      query = Rack::Utils.parse_query(uri.query)

      expect("#{uri.scheme}://#{uri.host}#{uri.path}").to eq("https://partner.shopeemobile.com/api/v2/shop/auth_partner")
      expect(query["partner_id"]).to eq("2011234")
      expect(query["redirect"]).to eq("https://api.example.com/api/v1/webhooks/shopee?state=abc")
      expect(query["sign"]).to match(/\A\h{64}\z/)
      expect(query["sign"]).to eq(
        service.public_sign("/api/v2/shop/auth_partner", query.fetch("timestamp").to_i)
      )
    end

    it "uses the sandbox base URL when environment=sandbox is stored in the credentials" do
      sandbox = described_class.new(base_credentials.merge("environment" => "sandbox"))

      url = sandbox.authorize_url(redirect_url: "https://api.example.com/cb")

      expect(url).to start_with("https://partner.test-stable.shopeemobile.com/api/v2/shop/auth_partner?")
    end
  end

  describe "#exchange_code" do
    it "posts code + shop_id + partner_id with the public sign in the query" do
      stub = stub_request(:post, token_get_url)
        .with(
          query: hash_including("partner_id" => "2011234", "sign" => /\h{64}/, "timestamp" => /\d+/),
          body: { code: "auth-code", shop_id: 9001, partner_id: 2_011_234 }.to_json
        )
        .to_return(
          status: 200,
          body: { error: "", message: "", access_token: "sp-access", refresh_token: "sp-refresh", expire_in: 14_400 }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      data = service.exchange_code(code: "auth-code", shop_id: "9001")

      expect(stub).to have_been_requested
      expect(data["access_token"]).to eq("sp-access")
      expect(data["refresh_token"]).to eq("sp-refresh")
    end

    it "raises AuthenticationError when Shopee returns an auth-flavored error in the body" do
      stub_request(:post, token_get_url)
        .with(query: hash_including("partner_id" => "2011234"))
        .to_return(
          status: 200,
          body: { error: "error_auth", message: "Invalid code" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      expect { service.exchange_code(code: "bad", shop_id: "9001") }
        .to raise_error(Integrations::AuthenticationError, /Invalid code/)
    end
  end

  describe ".refresh_credential!" do
    let(:tenant) { Tenant.create!(name: "Loja Teste", slug: "loja-#{SecureRandom.hex(4)}") }
    let(:credential) do
      tenant.channel_credentials.create!(
        channel: "shopee",
        status: "active",
        credentials: base_credentials.merge(
          "shop_id" => "9001",
          "access_token" => "old-access",
          "refresh_token" => "old-refresh"
        )
      )
    end

    it "persists the rotated access_token/refresh_token and the new expiry" do
      stub_request(:post, refresh_url)
        .with(
          query: hash_including("partner_id" => "2011234", "sign" => /\h{64}/),
          body: { refresh_token: "old-refresh", shop_id: 9001, partner_id: 2_011_234 }.to_json
        )
        .to_return(
          status: 200,
          body: { error: "", message: "", access_token: "new-access", refresh_token: "new-refresh", expire_in: 14_400 }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      described_class.refresh_credential!(credential)

      stored = credential.reload.credentials
      expect(stored["access_token"]).to eq("new-access")
      expect(stored["refresh_token"]).to eq("new-refresh")
      expect(Time.zone.parse(stored["token_expires_at"])).to be_within(1.minute).of(4.hours.from_now)
      expect(Time.zone.parse(stored["refresh_token_expires_at"])).to be_within(1.minute).of(30.days.from_now)
      expect(credential.status).to eq("active")
    end

    it "keeps the current refresh_token when the response omits a new one" do
      stub_request(:post, refresh_url)
        .with(query: hash_including("partner_id" => "2011234"))
        .to_return(
          status: 200,
          body: { error: "", message: "", access_token: "new-access", expire_in: 14_400 }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      described_class.refresh_credential!(credential)

      expect(credential.reload.credentials["refresh_token"]).to eq("old-refresh")
    end

    it "raises AuthenticationError without any HTTP call when the credential has no refresh_token" do
      credential.update!(credentials: base_credentials)

      expect { described_class.refresh_credential!(credential) }
        .to raise_error(Integrations::AuthenticationError, /sem refresh_token/)
      expect(WebMock).to have_not_requested(:post, refresh_url)
    end
  end
end
