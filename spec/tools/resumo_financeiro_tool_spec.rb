require "rails_helper"

RSpec.describe ResumoFinanceiroTool do
  let(:tenant)       { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:other_tenant) { Tenant.create!(name: "Outra Loja", slug: "outra-loja-#{SecureRandom.hex(4)}") }
  let(:user) { tenant.users.create!(name: "Ana", email: "ana@#{SecureRandom.hex(4)}.com", password: "password123") }

  after { Current.reset }

  # Mesma garantia que já existe pra API REST normal (Dashboard::BuildSummary
  # já é tenant-scoped) — aqui confirmando que o caminho MCP (Current.user
  # setado pelo monkey-patch de auth, não um current_tenant de request JWT)
  # resolve o tenant certo e não vaza dado de outro.
  it "scopes the summary to Current.user's tenant" do
    tenant.channels.create!(name: "Yampi", platform: "yampi")
    other_tenant.channels.create!(name: "Yampi", platform: "yampi")

    Current.user = user
    result = described_class.new.call

    expect(result).to be_a(Hash)
    expect(result.keys).to contain_exactly(:periodo, :kpis, :receita_por_canal, :financeiro)
  end

  it "returns a plain error message (not an exception) when there is no Current.user" do
    Current.user = nil
    expect { described_class.new.call }.not_to raise_error
    expect(described_class.new.call).to eq("Usuário sem tenant associado.")
  end
end
