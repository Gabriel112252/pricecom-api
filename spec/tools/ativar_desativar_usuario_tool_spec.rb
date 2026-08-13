require "rails_helper"

RSpec.describe AtivarDesativarUsuarioTool do
  let(:tenant)   { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:admin)    { tenant.users.create!(name: "Admin", email: "admin@#{SecureRandom.hex(4)}.com", password: "password123", role: "admin") }
  let(:operador) { tenant.users.create!(name: "Operador", email: "op@#{SecureRandom.hex(4)}.com", password: "password123", role: "operador") }

  after { Current.reset }

  it "requires admin" do
    target = tenant.users.create!(name: "Alvo", email: "alvo@#{SecureRandom.hex(4)}.com", password: "password123")
    Current.user = operador

    expect {
      result = described_class.new.call(usuario_id: target.id, ativar: false)
      expect(result).to eq("Acesso restrito a administradores.")
    }.not_to raise_error

    expect(target.reload.active).to eq(true)
  end

  it "deactivates and logs user.deactivated with source: mcp — reusing User#deactivate!, same guard as the REST endpoint" do
    target = tenant.users.create!(name: "Alvo", email: "alvo@#{SecureRandom.hex(4)}.com", password: "password123")
    Current.user = admin

    expect {
      described_class.new.call(usuario_id: target.id, ativar: false)
    }.to change(UserActivityLog, :count).by(1)

    expect(target.reload.active).to eq(false)
    log = UserActivityLog.last
    expect(log.action).to eq("user.deactivated")
    expect(log.metadata).to eq("source" => "mcp")
  end

  # Mesma trava de UsersController#destroy — reaproveitada via
  # User#deactivate!(actor:), não reimplementada aqui.
  it "blocks an admin from deactivating themselves, same rule as the REST endpoint" do
    Current.user = admin

    result = described_class.new.call(usuario_id: admin.id, ativar: false)

    expect(result).to match(/não pode desativar sua própria conta/i)
    expect(admin.reload.active).to eq(true)
  end

  it "reactivates and logs user.updated with source: mcp" do
    target = tenant.users.create!(name: "Alvo", email: "alvo@#{SecureRandom.hex(4)}.com", password: "password123", active: false)
    Current.user = admin

    described_class.new.call(usuario_id: target.id, ativar: true)

    expect(target.reload.active).to eq(true)
    log = UserActivityLog.last
    expect(log.action).to eq("user.updated")
    expect(log.metadata).to eq("active" => true, "source" => "mcp")
  end

  it "does not find a user from another tenant" do
    other_tenant = Tenant.create!(name: "Outra Loja", slug: "outra-loja-#{SecureRandom.hex(4)}")
    outsider = other_tenant.users.create!(name: "Fora", email: "fora@#{SecureRandom.hex(4)}.com", password: "password123")
    Current.user = admin

    result = described_class.new.call(usuario_id: outsider.id, ativar: false)

    expect(result).to match(/não encontrado/i)
    expect(outsider.reload.active).to eq(true)
  end
end
