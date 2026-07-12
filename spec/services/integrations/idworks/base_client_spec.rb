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
  end
end
