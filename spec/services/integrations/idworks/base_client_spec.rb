require "rails_helper"

RSpec.describe Integrations::Idworks::BaseClient do
  let(:credentials) { { base_url: "https://cliente.idworks.com.br/1.0", email: "user@hidrabene.com", password: "secret" } }
  let(:client) { described_class.new(credentials) }
  let(:signin_fixture) { File.read(Rails.root.join("spec/fixtures/integrations/idworks_signin.json")) }
  let(:token) { JSON.parse(signin_fixture)["token"] }

  def stub_signin
    stub_request(:post, "https://cliente.idworks.com.br/1.0/user/signin/local")
      .to_return(status: 200, body: signin_fixture, headers: { "Content-Type" => "application/json" })
  end

  describe "#authenticate!" do
    it "signs in and returns true" do
      stub_signin
      expect(client.authenticate!).to eq(true)
    end
  end

  describe "#get" do
    it "signs in lazily on first call and attaches Bearer/Origin/FilePath to every request" do
      stub_signin
      stub_request(:get, "https://cliente.idworks.com.br/1.0/sku")
        .with(headers: { "Authorization" => "Bearer #{token}", "Origin" => "https://erp-www.idworks.com.br", "Filepath" => "" })
        .to_return(status: 200, body: { "Data" => [] }.to_json, headers: { "Content-Type" => "application/json" })

      client.get("sku")

      expect(WebMock).to have_requested(:post, "https://cliente.idworks.com.br/1.0/user/signin/local").once
    end

    it "reuses the token across multiple calls instead of signing in again" do
      stub_signin
      stub_request(:get, "https://cliente.idworks.com.br/1.0/sku")
        .to_return(status: 200, body: { "Data" => [] }.to_json, headers: { "Content-Type" => "application/json" })

      client.get("sku")
      client.get("sku")

      expect(WebMock).to have_requested(:post, "https://cliente.idworks.com.br/1.0/user/signin/local").once
    end

    it "proactively re-signs in once the token's expiration is within the safety margin, without waiting for a 403" do
      stub_request(:post, "https://cliente.idworks.com.br/1.0/user/signin/local")
        .to_return(
          { status: 200, body: { token: "token-1", expiration: 1.minute.from_now.iso8601 }.to_json, headers: { "Content-Type" => "application/json" } },
          { status: 200, body: { token: "token-2", expiration: 1.day.from_now.iso8601 }.to_json, headers: { "Content-Type" => "application/json" } }
        )
      stub_request(:get, "https://cliente.idworks.com.br/1.0/sku")
        .to_return(status: 200, body: { "Data" => [] }.to_json, headers: { "Content-Type" => "application/json" })

      client.get("sku")
      client.get("sku")

      expect(WebMock).to have_requested(:post, "https://cliente.idworks.com.br/1.0/user/signin/local").twice
      expect(WebMock).to have_requested(:get, "https://cliente.idworks.com.br/1.0/sku")
        .with(headers: { "Authorization" => "Bearer token-2" }).once
    end

    it "re-signs in and retries once when idworks rejects the session mid-run (403, e.g. an expired token the client didn't know about yet)" do
      stub_signin
      stub_request(:get, "https://cliente.idworks.com.br/1.0/sku")
        .to_return(
          { status: 403, body: { error: "no identity-based policy allows the execute-api:Invoke action" }.to_json },
          { status: 200, body: { "Data" => [] }.to_json, headers: { "Content-Type" => "application/json" } }
        )

      expect(client.get("sku")).to eq({ "Data" => [] })
      expect(WebMock).to have_requested(:post, "https://cliente.idworks.com.br/1.0/user/signin/local").twice
      expect(WebMock).to have_requested(:get, "https://cliente.idworks.com.br/1.0/sku").twice
    end

    it "gives up after one retry — a 403 that persists after re-signing in raises, instead of looping forever" do
      stub_signin
      stub_request(:get, "https://cliente.idworks.com.br/1.0/sku")
        .to_return(status: 403, body: { error: "no identity-based policy allows the execute-api:Invoke action" }.to_json)

      expect { client.get("sku") }.to raise_error(Integrations::AuthenticationError)
      expect(WebMock).to have_requested(:post, "https://cliente.idworks.com.br/1.0/user/signin/local").twice
      expect(WebMock).to have_requested(:get, "https://cliente.idworks.com.br/1.0/sku").twice
    end
  end
end
