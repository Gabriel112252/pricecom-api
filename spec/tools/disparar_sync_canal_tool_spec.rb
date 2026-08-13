require "rails_helper"

RSpec.describe DispararSyncCanalTool do
  let(:tenant)   { Tenant.create!(name: "Loja Teste", slug: "loja-teste-#{SecureRandom.hex(4)}") }
  let(:admin)    { tenant.users.create!(name: "Admin", email: "admin@#{SecureRandom.hex(4)}.com", password: "password123", role: "admin") }
  let(:operador) { tenant.users.create!(name: "Operador", email: "op@#{SecureRandom.hex(4)}.com", password: "password123", role: "operador") }

  after { Current.reset }

  # Mesmo padrão de spec/requests/api/v1/channel_credentials_spec.rb —
  # troca pro adapter :test só durante o exemplo, pra inspecionar a fila
  # sem depender de Redis/Sidekiq de verdade rodando.
  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    example.run
    ActiveJob::Base.queue_adapter = original_adapter
  end

  it "requires admin" do
    Current.user = operador

    expect {
      result = described_class.new.call(canal: "yampi")
      expect(result).to eq("Acesso restrito a administradores.")
    }.not_to raise_error
  end

  it "rejects a channel without manual polling support" do
    Current.user = admin
    result = described_class.new.call(canal: "mercadolivre")
    expect(result).to match(/não suporta sincronização manual/i)
  end

  it "rejects when the channel isn't connected yet" do
    Current.user = admin
    result = described_class.new.call(canal: "yampi")
    expect(result).to match(/não está conectado/i)
  end

  it "enqueues the polling job and logs channel_sync.triggered with source: mcp" do
    Current.user = admin
    tenant.channel_credentials.create!(channel: "yampi", status: "active", credentials: { alias: "loja", token: "t", secret_key: "s", webhook_secret: "wh" })

    expect {
      described_class.new.call(canal: "yampi")
    }.to change(UserActivityLog, :count).by(1)

    enqueued = ActiveJob::Base.queue_adapter.enqueued_jobs
    expect(enqueued.size).to eq(1)
    expect(enqueued.first[:job]).to eq(Integrations::Yampi::OrdersPollingJob)
    expect(enqueued.first[:args].last).to include("trigger" => "mcp")

    log = UserActivityLog.last
    expect(log.action).to eq("channel_sync.triggered")
    expect(log.metadata).to eq("channel" => "yampi", "source" => "mcp")
  end
end
