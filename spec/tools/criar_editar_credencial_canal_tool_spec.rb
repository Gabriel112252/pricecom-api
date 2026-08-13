require "rails_helper"

RSpec.describe CriarEditarCredencialCanalTool do
  let(:tenant)    { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:admin)     { tenant.users.create!(name: "Admin", email: "admin@#{SecureRandom.hex(4)}.com", password: "password123", role: "admin") }
  let(:operador)  { tenant.users.create!(name: "Operador", email: "op@#{SecureRandom.hex(4)}.com", password: "password123", role: "operador") }

  let(:credenciais) { { "app_key" => "key123", "app_secret" => "supersecreto" } }

  after { Current.reset }

  it "requires admin — an operador gets a plain error message, not an exception" do
    Current.user = operador

    expect {
      result = described_class.new.call(canal: "tiktok", credenciais: credenciais, confirmar: true)
      expect(result).to eq("Acesso restrito a administradores.")
    }.not_to raise_error

    expect(tenant.channel_credentials.where(channel: "tiktok")).to be_empty
  end

  it "requires confirmar: true — without it, nothing is executed" do
    Current.user = admin

    result = described_class.new.call(canal: "tiktok", credenciais: credenciais, confirmar: false)

    expect(result).to match(/confirma/i)
    expect(tenant.channel_credentials.where(channel: "tiktok")).to be_empty
  end

  it "rejects an unknown channel without touching anything" do
    Current.user = admin

    result = described_class.new.call(canal: "aliexpress", credenciais: credenciais, confirmar: true)

    expect(result).to match(/inválido/i)
    expect(tenant.channel_credentials.count).to eq(0)
  end

  it "saves the credential and logs channel_credential.updated with source: mcp, never the credential values" do
    Current.user = admin

    expect {
      described_class.new.call(canal: "tiktok", credenciais: credenciais, confirmar: true)
    }.to change(UserActivityLog, :count).by(1)

    credential = tenant.channel_credentials.find_by!(channel: "tiktok")
    expect(credential.credentials).to include("app_key" => "key123")

    log = UserActivityLog.last
    expect(log.action).to eq("channel_credential.updated")
    expect(log.metadata).to eq("channel" => "tiktok", "source" => "mcp")
    expect(log.metadata.to_s).not_to include("supersecreto")
    expect(log.user).to eq(admin)
  end

  it "does not leak into another tenant" do
    Current.user = admin

    described_class.new.call(canal: "tiktok", credenciais: credenciais, confirmar: true)

    other_tenant = Tenant.create!(name: "Outra Loja", slug: "outra-loja-#{SecureRandom.hex(4)}")
    expect(other_tenant.channel_credentials.where(channel: "tiktok")).to be_empty
  end
end
