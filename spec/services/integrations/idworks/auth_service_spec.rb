require "rails_helper"

RSpec.describe Integrations::Idworks::AuthService do
  let(:credentials) { { base_url: "https://cliente.idworks.com.br/1.0", email: "user@hidrabene.com", password: "secret" } }
  let(:signin_url) { "https://cliente.idworks.com.br/1.0/user/signin/local" }
  let(:signin_fixture) { File.read(Rails.root.join("spec/fixtures/integrations/idworks_signin.json")) }

  it "signs in with email/password and the required Origin/FilePath headers, returning token+expiration" do
    stub_request(:post, signin_url)
      .with(
        body: { email: "user@hidrabene.com", password: "secret" }.to_json,
        headers: { "Origin" => "https://erp-www.idworks.com.br", "Filepath" => "" }
      )
      .to_return(status: 200, body: signin_fixture, headers: { "Content-Type" => "application/json" })

    result = described_class.call(credentials)

    expect(result[:token]).to eq(JSON.parse(signin_fixture)["token"])
    expect(result[:expiration]).to eq(JSON.parse(signin_fixture)["expiration"])
  end

  it "raises AuthenticationError when idworks rejects the email/password" do
    stub_request(:post, signin_url).to_return(status: 401, body: { message: "Invalid credentials" }.to_json)

    expect { described_class.call(credentials) }.to raise_error(Integrations::AuthenticationError)
  end
end
