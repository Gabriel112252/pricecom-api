# frozen_string_literal: true

class BaixarVideosAfiliadasEmLoteTool < ApplicationTool
  include AffiliateVideoFilters

  description "Gera de uma vez o link de download (vale 24 horas) de vários vídeos de afiliadas: os de uma lista de ids " \
    "ou os de um filtro (os mesmos de listar_videos_afiliadas, na ordem escolhida). Os que já estão no Pricecom voltam " \
    "com o link; os outros entram na fila de download. Rode de novo o mesmo pedido em alguns minutos (cerca de 1 " \
    "minuto a cada 20 vídeos) para receber os links que faltam. Até 200 vídeos por chamada."

  MAX_PER_CALL = 200
  DEFAULT_LIMIT = 50
  VIDEOS_PER_MINUTE = 20

  arguments do
    optional(:ids).filled(:string).description("IDs dos vídeos separados por vírgula (campo id de listar_videos_afiliadas). Se vier, os filtros são ignorados")
    optional(:criadora).filled(:string).description("@ ou nome da criadora (busca parcial, sem diferenciar maiúsculas)")
    optional(:produto).filled(:string).description("ID ou parte do nome do produto divulgado")
    optional(:from).filled(:string).description("Postados a partir de (YYYY-MM-DD)")
    optional(:to).filled(:string).description("Postados até (YYYY-MM-DD)")
    optional(:ordem).filled(:string).description("recentes (padrão), gmv (mais vendas primeiro) ou views (mais vistos primeiro)")
    optional(:limite).filled(:integer).description("Quantos vídeos do filtro, na ordem escolhida (padrão 50, máx 200)")
  end

  def call(ids: nil, criadora: nil, produto: nil, from: nil, to: nil, ordem: nil, limite: nil)
    tenant = current_tenant
    return "Usuário sem tenant associado." unless tenant

    order_scope = affiliate_video_order(ordem)
    return INVALID_ORDER unless order_scope

    base = tenant.affiliate_videos.includes(file_attachment: :blob)
    videos, not_found =
      if ids.present?
        by_ids(base, ids)
      else
        filtered = filter_affiliate_videos(base, criadora: criadora, produto: produto, from: from, to: to)
        [ filtered.public_send(order_scope).limit(limit_for(limite)).to_a, [] ]
      end

    ready = []
    queued = 0
    in_progress = 0
    videos.each do |video|
      case video.request_download!
      when :downloaded then ready << link_entry(video)
      when :in_progress then in_progress += 1
      else queued += 1
      end
    end

    {
      total: videos.size,
      com_link: ready.size,
      entraram_na_fila: queued,
      ja_baixando: in_progress,
      nao_encontrados: not_found.presence,
      links_expiram_em: AffiliateVideo::DOWNLOAD_LINK_TTL.from_now.iso8601,
      proximo_passo: next_step(queued + in_progress),
      videos: ready
    }.compact
  rescue Date::Error, ArgumentError
    INVALID_DATE
  end

  private

  def by_ids(base, ids)
    wanted = ids.to_s.split(/[\s,;]+/).map(&:strip).reject(&:blank?).uniq.first(MAX_PER_CALL)
    found = base.where(video_id: wanted).index_by(&:video_id)
    [ wanted.filter_map { |id| found[id] }, wanted - found.keys ]
  end

  def limit_for(limite)
    limite.to_i.positive? ? [ limite.to_i, MAX_PER_CALL ].min : DEFAULT_LIMIT
  end

  def link_entry(video)
    {
      id: video.video_id,
      criadora: video.username.present? ? "@#{video.username}" : nil,
      link_download: video.download_link
    }.compact
  end

  def next_step(pending)
    return "Todos os vídeos pedidos já têm link." if pending.zero?

    minutes = (pending / VIDEOS_PER_MINUTE.to_f).ceil
    "#{pending} vídeo(s) ainda sem arquivo no Pricecom. Rode de novo o mesmo pedido em cerca de #{minutes} minuto(s) para receber os links."
  end
end
