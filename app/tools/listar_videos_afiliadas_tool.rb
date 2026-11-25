# frozen_string_literal: true

class ListarVideosAfiliadasTool < ApplicationTool
  include AffiliateVideoFilters

  description "Lista os vídeos que criadoras afiliadas com colaboração direcionada postaram para a loja no TikTok Shop, " \
    "com métricas, produtos e status do download do arquivo. Cada vídeo já baixado vem com link_download (vale 24 " \
    "horas). Para gerar o link dos que ainda não foram baixados, use BaixarVideosAfiliadasEmLoteTool com o mesmo " \
    "filtro. Se a lista vier vazia ou desatualizada, rode sincronizar_videos_afiliadas antes. Use ordem gmv para ver " \
    "primeiro os que mais venderam (as métricas são do período em metricas_do_periodo) e pagina para percorrer a " \
    "lista inteira."

  RESULT_LIMIT = 50
  DEFAULT_LIMIT = 25

  arguments do
    optional(:criadora).filled(:string).description("@ ou nome da criadora (busca parcial, sem diferenciar maiúsculas)")
    optional(:produto).filled(:string).description("ID ou parte do nome do produto divulgado")
    optional(:from).filled(:string).description("Postados a partir de (YYYY-MM-DD)")
    optional(:to).filled(:string).description("Postados até (YYYY-MM-DD)")
    optional(:somente_baixados).filled(:bool).description("true = só vídeos com o arquivo já baixado")
    optional(:ordem).filled(:string).description("recentes (padrão, postados mais novos primeiro), gmv (mais vendas primeiro) ou views (mais vistos primeiro)")
    optional(:limite).filled(:integer).description("Máximo de vídeos por página (padrão 25, máx 50)")
    optional(:pagina).filled(:integer).description("Página da lista (1, 2, 3...), para percorrer todos os vídeos do filtro")
  end

  def call(criadora: nil, produto: nil, from: nil, to: nil, somente_baixados: false, ordem: nil, limite: nil, pagina: nil)
    tenant = current_tenant
    return "Usuário sem tenant associado." unless tenant

    order_scope = affiliate_video_order(ordem)
    return INVALID_ORDER unless order_scope

    scope = filter_affiliate_videos(tenant.affiliate_videos, criadora: criadora, produto: produto, from: from, to: to)
    scope = scope.downloaded if somente_baixados

    limit = limite.to_i.positive? ? [ limite.to_i, RESULT_LIMIT ].min : DEFAULT_LIMIT
    page = [ pagina.to_i, 1 ].max
    total = scope.count
    videos = scope.includes(file_attachment: :blob).public_send(order_scope).offset((page - 1) * limit).limit(limit)

    {
      total_no_filtro: total,
      pagina: page,
      paginas: (total.to_f / limit).ceil,
      ultima_sincronizacao: last_sync_summary(tenant),
      links_expiram_em: AffiliateVideo::DOWNLOAD_LINK_TTL.from_now.iso8601,
      videos: videos.map { |video| video_summary(video) }
    }
  rescue Date::Error, ArgumentError
    INVALID_DATE
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
      link_download: video.download_link,
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
