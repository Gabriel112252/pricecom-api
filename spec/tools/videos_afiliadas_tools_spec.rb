require "rails_helper"

RSpec.describe "Ferramentas MCP de vídeos de afiliadas" do
  let(:tenant)   { Tenant.create!(name: "Loja Vídeos", slug: "videos-mcp-#{SecureRandom.hex(4)}") }
  let(:other_tenant) { Tenant.create!(name: "Outra", slug: "outra-#{SecureRandom.hex(4)}") }
  let(:admin)    { tenant.users.create!(name: "Admin", email: "admin@#{SecureRandom.hex(4)}.com", password: "password123", role: "admin") }
  let(:operador) { tenant.users.create!(name: "Operador", email: "op@#{SecureRandom.hex(4)}.com", password: "password123", role: "operador") }
  let(:channel)  { Channel.ensure_for!(tenant, "tiktok") }
  let(:video_bytes) { "\x00\x00\x00\x18ftypmp42fake-video-bytes".b }

  after { Current.reset }

  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    example.run
    ActiveJob::Base.queue_adapter = original_adapter
  end

  def create_video(video_id, attrs = {})
    channel.affiliate_videos.create!({ tenant: tenant, video_id: video_id, username: "criadora_a", nickname: "Criadora A" }.merge(attrs))
  end

  def downloaded_video(video_id, attrs = {})
    video = create_video(video_id, attrs)
    video.file.attach(io: StringIO.new(video_bytes), filename: "criadora_a-#{video_id}.mp4", content_type: "video/mp4")
    video.update!(download_status: "downloaded")
    video
  end

  def enqueued_downloads
    ActiveJob::Base.queue_adapter.enqueued_jobs.select { |job| job[:job] == Integrations::Tiktok::AffiliateVideoDownloadJob }
  end

  describe ListarVideosAfiliadasTool do
    before { Current.user = operador }

    it "lists the tenant's videos newest first, with filters" do
      create_video("1", posted_at: Time.zone.parse("2026-11-01 10:00"), products: [ { "id" => "p1", "name" => "Sérum Vitamina C" } ], metrics: { "views" => 10 })
      create_video("2", posted_at: Time.zone.parse("2026-11-20 10:00"), username: "outra", nickname: "Outra")
      other_channel = Channel.ensure_for!(other_tenant, "tiktok")
      other_channel.affiliate_videos.create!(tenant: other_tenant, video_id: "99", username: "criadora_a")

      result = described_class.new.call

      expect(result[:total_no_filtro]).to eq(2)
      expect(result[:videos].map { |v| v[:id] }).to eq(%w[2 1])
      expect(result[:ultima_sincronizacao]).to eq("nunca sincronizado")

      by_creator = described_class.new.call(criadora: "@Criadora_A")
      expect(by_creator[:videos].map { |v| v[:id] }).to eq(%w[1])
      expect(by_creator[:videos].first).to include(criadora: "@criadora_a", visualizacoes: 10, produtos: [ "Sérum Vitamina C" ])

      by_product = described_class.new.call(produto: "vitamina")
      expect(by_product[:videos].map { |v| v[:id] }).to eq(%w[1])

      by_date = described_class.new.call(from: "2026-11-15")
      expect(by_date[:videos].map { |v| v[:id] }).to eq(%w[2])
    end

    it "orders by GMV or views when asked, newest first by default, and rejects an unknown order" do
      create_video("1", posted_at: Time.zone.parse("2026-11-20 10:00"), metrics: { "gmv" => { "amount" => "10.00", "currency" => "BRL" }, "views" => 900 })
      create_video("2", posted_at: Time.zone.parse("2026-11-01 10:00"), metrics: { "gmv" => { "amount" => "2500.00", "currency" => "BRL" }, "views" => 50 })
      create_video("3", posted_at: Time.zone.parse("2026-11-10 10:00"))

      expect(described_class.new.call(ordem: "gmv")[:videos].map { |v| v[:id] }).to eq(%w[2 1 3])
      expect(described_class.new.call(ordem: "views")[:videos].map { |v| v[:id] }).to eq(%w[1 2 3])
      expect(described_class.new.call[:videos].map { |v| v[:id] }).to eq(%w[1 3 2])
      expect(described_class.new.call(ordem: "aleatorio")).to match(/Ordem inválida/)
    end

    it "rejects a malformed date" do
      expect(described_class.new.call(from: "2026-13-45")).to match(/Data inválida/)
    end

    it "includes a 24h download link for each downloaded video and pages through the list" do
      downloaded_video("1", posted_at: Time.zone.parse("2026-11-20 10:00"))
      create_video("2", posted_at: Time.zone.parse("2026-11-10 10:00"))

      first_page = described_class.new.call(limite: 1)

      expect(first_page).to include(total_no_filtro: 2, pagina: 1, paginas: 2)
      expect(first_page[:videos].map { |v| v[:id] }).to eq(%w[1])
      expect(first_page[:videos].first[:link_download]).to include("/rails/active_storage/blobs/redirect/")

      second_page = described_class.new.call(limite: 1, pagina: 2)

      expect(second_page[:videos].map { |v| v[:id] }).to eq(%w[2])
      expect(second_page[:videos].first).not_to have_key(:link_download)
    end
  end

  describe BaixarVideosAfiliadasEmLoteTool do
    before { Current.user = operador }

    it "returns links for the downloaded videos of a filter and queues the rest, top GMV first" do
      downloaded_video("1", metrics: { "gmv" => { "amount" => "900.00", "currency" => "BRL" } })
      pending_video = create_video("2", metrics: { "gmv" => { "amount" => "500.00", "currency" => "BRL" } })
      create_video("3", metrics: { "gmv" => { "amount" => "10.00", "currency" => "BRL" } })
      create_video("4", username: "outra", nickname: "Outra")

      result = described_class.new.call(criadora: "criadora_a", ordem: "gmv", limite: 2)

      expect(result).to include(total: 2, com_link: 1, entraram_na_fila: 1, ja_baixando: 0)
      expect(result[:videos].map { |v| v[:id] }).to eq(%w[1])
      expect(result[:videos].first[:link_download]).to include("/rails/active_storage/blobs/redirect/")
      expect(result[:proximo_passo]).to match(/Rode de novo/)
      expect(pending_video.reload.download_status).to eq("queued")
      expect(enqueued_downloads.map { |job| job[:args] }).to eq([ [ pending_video.id ] ])
    end

    it "takes explicit ids, reports the unknown ones and doesn't queue a download in progress twice" do
      downloaded_video("10")
      create_video("11", download_status: "downloading")
      other_channel = Channel.ensure_for!(other_tenant, "tiktok")
      other_channel.affiliate_videos.create!(tenant: other_tenant, video_id: "12")

      result = described_class.new.call(ids: "10, 11 12,99")

      expect(result).to include(total: 2, com_link: 1, entraram_na_fila: 0, ja_baixando: 1, nao_encontrados: %w[12 99])
      expect(enqueued_downloads).to be_empty
    end

    it "caps a filter at MAX_PER_CALL videos" do
      stub_const("#{described_class}::MAX_PER_CALL", 2)
      %w[a b c].each { |id| create_video(id) }

      result = described_class.new.call(limite: 500)

      expect(result).to include(total: 2, entraram_na_fila: 2)
      expect(enqueued_downloads.size).to eq(2)
    end

    it "rejects a malformed date or an unknown order" do
      expect(described_class.new.call(from: "2026-13-45")).to match(/Data inválida/)
      expect(described_class.new.call(ordem: "aleatorio")).to match(/Ordem inválida/)
    end
  end

  describe BaixarVideoAfiliadaTool do
    before { Current.user = operador }

    it "returns an expiring download link for a downloaded video" do
      video = create_video("7300000000000000001")
      video.file.attach(io: StringIO.new(video_bytes), filename: "criadora_a-7300000000000000001.mp4", content_type: "video/mp4")
      video.update!(download_status: "downloaded")

      result = described_class.new.call(video_id: "7300000000000000001")

      expect(result[:status]).to eq("baixado")
      expect(result[:link_download]).to include("/rails/active_storage/blobs/redirect/")
      expect(result[:link_download]).to end_with("/criadora_a-7300000000000000001.mp4")
      # Attaching the file enqueues Active Storage's own AnalyzeJob; what
      # matters is that no second download was queued.
      enqueued = ActiveJob::Base.queue_adapter.enqueued_jobs.map { |job| job[:job] }
      expect(enqueued).not_to include(Integrations::Tiktok::AffiliateVideoDownloadJob)
    end

    it "says when everything asked already has a link" do
      downloaded_video("7300000000000000009")

      result = BaixarVideosAfiliadasEmLoteTool.new.call(ids: "7300000000000000009")

      expect(result).to include(com_link: 1, proximo_passo: "Todos os vídeos pedidos já têm link.")
    end

    it "queues the download when the file isn't there yet, keeping the previous error for context" do
      video = create_video("7300000000000000002", download_status: "failed", download_error: "HTTP 403")

      result = described_class.new.call(video_id: "7300000000000000002")

      expect(result).to include(status: "download_iniciado", erro_anterior: "HTTP 403")
      expect(video.reload.download_status).to eq("queued")
      enqueued = ActiveJob::Base.queue_adapter.enqueued_jobs
      expect(enqueued.map { |job| job[:job] }).to eq([ Integrations::Tiktok::AffiliateVideoDownloadJob ])
      expect(enqueued.first[:args]).to eq([ video.id ])
    end

    it "doesn't queue twice while a download is in progress" do
      create_video("7300000000000000003", download_status: "downloading")

      result = described_class.new.call(video_id: "7300000000000000003")

      expect(result[:status]).to eq("baixando")
      expect(ActiveJob::Base.queue_adapter.enqueued_jobs).to be_empty
    end

    it "never returns another tenant's video" do
      other_channel = Channel.ensure_for!(other_tenant, "tiktok")
      other_channel.affiliate_videos.create!(tenant: other_tenant, video_id: "555")

      expect(described_class.new.call(video_id: "555")).to match(/não encontrado/)
    end
  end

  describe SincronizarVideosAfiliadasTool do
    it "requires admin" do
      Current.user = operador
      expect(described_class.new.call).to eq("Acesso restrito a administradores.")
    end

    it "explains when TikTok isn't connected" do
      Current.user = admin
      expect(described_class.new.call).to match(/não está conectado/)
    end

    it "queues one sync per active TikTok connection, clamping the days and logging the trigger" do
      Current.user = admin
      credential = tenant.channel_credentials.create!(
        channel: "tiktok", status: "active",
        credentials: { app_key: "key", app_secret: "secret", access_token: "token", shop_cipher: "cipher" }
      )

      result = nil
      expect { result = described_class.new.call(dias: 1000) }.to change(UserActivityLog, :count).by(1)

      expect(result).to include(dias: 365)
      enqueued = ActiveJob::Base.queue_adapter.enqueued_jobs
      expect(enqueued.map { |job| job[:job] }).to eq([ Integrations::Tiktok::AffiliateVideoSyncJob ])
      expect(enqueued.first[:args].first).to eq(credential.id)
      expect(enqueued.first[:args].last).to include("days_back" => 365)
      expect(UserActivityLog.last.metadata).to include("kind" => "affiliate_videos", "source" => "mcp")
    end
  end
end
