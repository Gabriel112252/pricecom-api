# frozen_string_literal: true

class ListarVideosAfiliadasTool < ApplicationTool
  description "Lista os vídeos que criadoras afiliadas com colaboração direcionada postaram para a loja no TikTok Shop, " \
    "com métricas, produtos e status do download do arquivo. Se a lista vier vazia ou desatualizada, " \
    "rode sincronizar_videos_afiliadas antes. Para pegar o arquivo de um vídeo, use baixar_video_afiliada com o id."

  RESULT_LIMIT = 50
  DEFAULT_LIMIT = 25

  arguments do
    optional(:criadora).filled(:string).description("@ ou nome da criadora (busca parcial, sem diferenciar maiúsculas)")
    optional(:produto).filled(:string).description("ID ou parte do nome do produto divulgado")
    optional(:from).filled(:string).description("Postados a partir de (YYYY-MM-DD)")
    optional(:to).filled(:string).description("Postados até (YYYY-MM-DD)")
    optional(:somente_baixados).filled(:bool).description("true = só vídeos com o arquivo já baixado")
    optional(:limite).filled(:integer).description("Máximo de vídeos (padrão 25, máx 50)")
  end

  def call(criadora: nil, produto: nil, from: nil, to: nil, somente_baixados: false, limite: nil)
    tenant = current_tenant
    return "Usuário sem tenant associado." unless tenant

    scope = tenant.affiliate_videos
    if criadora.present?
      term = "%#{ActiveRecord::Base.sanitize_sql_like(criadora.to_s.delete_prefix("@").downcase)}%"
      scope = scope.where("LOWER(affiliate_videos.username) LIKE :term OR LOWER(affiliate_videos.nickname) LIKE :term", term: term)
    end
    if produto.present?
      scope = scope.where("affiliate_videos.products::text ILIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(produto.to_s)}%")
    end
    scope = scope.where("affiliate_videos.posted_at >= ?", Date.parse(from).beginning_of_day) if from.present?
    scope = scope.where("affiliate_videos.posted_at <= ?", Date.parse(to).end_of_day) if to.present?
    scope = scope.downloaded if somente_baixados

    limit = limite.to_i.positive? ? [ limite.to_i, RESULT_LIMIT ].min : DEFAULT_LIMIT
    videos = scope.includes(file_attachment: :blob)
      .order(Arel.sql("affiliate_videos.posted_at DESC NULLS LAST, affiliate_videos.id DESC"))
      .limit(limit)

    {
      total_no_filtro: scope.count,
      ultima_sincronizacao: last_sync_summary(tenant),
      videos: videos.map { |video| video_summary(video) }
    }
  rescue Date::Error, ArgumentError
    "Data inválida. Use o formato YYYY-MM-DD."
  end

  private

  def video_summary(video)
    metrics = video.metrics || {}
    {
      id: video.video_id,
      titulo: video.title,
      criadora: video.username.present? ? "@#{video.username}" : nil,
      nome_criadora: video.nickname,
      postado_em: video.posted_at,
      duracao_segundos: video.duration_seconds,
      produtos: Array(video.products).map { |p| p["name"].presence || p["id"] }.compact,
      visualizacoes: metrics["views"],
      curtidas: metrics["likes"],
      itens_vendidos: metrics["items_sold"],
      gmv: metrics["gmv"],
      metricas_do_periodo: metrics["window"],
      link_tiktok: video.tiktok_url,
      download: video.downloaded? ? "baixado" : video.download_status,
      erro_download: video.download_status == "failed" ? video.download_error : nil
    }.compact
  end

  def last_sync_summary(tenant)
    log = tenant.integration_sync_logs
      .where(action: Integrations::Tiktok::AffiliateVideoSyncService::ACTION)
      .order(created_at: :desc).first
    return "nunca sincronizado" unless log

    { status: log.status, inicio: log.started_at, fim: log.finished_at, erro: log.error_message }.compact
  end
end
