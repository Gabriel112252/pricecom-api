# frozen_string_literal: true

class BaixarVideoAfiliadaTool < ApplicationTool
  description "Devolve o link para baixar o arquivo de um vídeo de afiliada (id que aparece em listar_videos_afiliadas). " \
    "O link vale por 24 horas. Se o arquivo ainda não estiver no Pricecom, dispara o download e pede para consultar de " \
    "novo em 1 a 2 minutos."

  LINK_TTL = 24.hours

  arguments do
    required(:video_id).filled(:string).description("ID do vídeo no TikTok (campo id de listar_videos_afiliadas)")
  end

  def call(video_id:)
    tenant = current_tenant
    return "Usuário sem tenant associado." unless tenant

    video = tenant.affiliate_videos.find_by(video_id: video_id.to_s.strip)
    return "Vídeo '#{video_id}' não encontrado entre os vídeos de afiliadas. Rode sincronizar_videos_afiliadas e confira o id." unless video

    return download_link(video) if video.downloaded?

    if video.download_in_progress?
      return { video_id: video.video_id, status: "baixando", mensagem: "O download já está em andamento. Consulte de novo em 1 a 2 minutos." }
    end

    previous_error = video.download_status == "failed" ? video.download_error : nil
    video.update!(download_status: "queued", download_error: nil)
    Integrations::Tiktok::AffiliateVideoDownloadJob.perform_later(video.id)

    {
      video_id: video.video_id,
      status: "download_iniciado",
      mensagem: "Download iniciado. Consulte de novo em 1 a 2 minutos para receber o link.",
      erro_anterior: previous_error
    }.compact
  end

  private

  def download_link(video)
    blob = video.file.blob
    url = Rails.application.routes.url_helpers.rails_service_blob_url(
      blob.signed_id(expires_in: LINK_TTL),
      blob.filename.to_s,
      host: link_host
    )

    {
      video_id: video.video_id,
      status: "baixado",
      arquivo: blob.filename.to_s,
      tamanho_mb: (blob.byte_size / 1.megabyte.to_f).round(1),
      link_download: url,
      link_expira_em: LINK_TTL.from_now.iso8601,
      link_tiktok: video.tiktok_url
    }.compact
  end

  def link_host
    Rails.application.routes.default_url_options[:host].presence || ENV["APP_HOST"].presence || "http://localhost:3000"
  end
end
