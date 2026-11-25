module Api
  module V1
    # Aba "Vídeos" da página Afiliados: os vídeos das criadoras com
    # colaboração direcionada. Assistir é pelo link do TikTok (tiktok_url);
    # baixar é pelo arquivo guardado no Pricecom (download_url, vale 24h).
    # Um vídeo que ainda não tem arquivo vai para a fila por #download, e o
    # front consulta #show até o link aparecer.
    class AffiliateVideosController < ApplicationController
      include AffiliateVideoFilters

      PER_PAGE_DEFAULT = 25
      PER_PAGE_MAX = 100

      # GET /api/v1/affiliate_videos?ordem=gmv&criadora=&produto=&from=&to=&somente_baixados=true&page=
      def index
        order_scope = affiliate_video_order(params[:ordem])
        return render(json: { errors: [ INVALID_ORDER ] }, status: :unprocessable_entity) unless order_scope

        scope = filter_affiliate_videos(
          current_tenant.affiliate_videos,
          criadora: params[:criadora], produto: params[:produto], from: params[:from], to: params[:to]
        )
        scope = scope.downloaded if ActiveModel::Type::Boolean.new.cast(params[:somente_baixados])
        per = [ [ params.fetch(:per_page, PER_PAGE_DEFAULT).to_i, 1 ].max, PER_PAGE_MAX ].min
        paged = scope.includes(file_attachment: :blob).public_send(order_scope).page(params[:page]).per(per)

        render json: { rows: paged.map { |video| video_json(video) }, meta: pagination_meta(paged), last_sync: last_sync }
      rescue Date::Error
        render json: { errors: [ INVALID_DATE ] }, status: :unprocessable_entity
      end

      # GET /api/v1/affiliate_videos/:id — o front consulta isto enquanto o
      # download está na fila.
      def show
        render json: video_json(current_tenant.affiliate_videos.includes(file_attachment: :blob).find(params[:id]))
      end

      # POST /api/v1/affiliate_videos/:id/download — devolve o link se o
      # arquivo já está no Pricecom; senão coloca o download na fila (sem
      # duplicar um que já está baixando).
      def download
        video = current_tenant.affiliate_videos.find(params[:id])
        status = video.request_download!

        render json: { id: video.id, download_status: status.to_s, download_url: video.download_link }.compact
      end

      private

      def video_json(video)
        metrics = video.metrics.is_a?(Hash) ? video.metrics : {}
        gmv = metrics["gmv"]
        downloaded = video.downloaded?
        {
          id: video.id,
          video_id: video.video_id,
          title: video.title,
          username: video.username,
          nickname: video.nickname,
          posted_at: video.posted_at,
          duration_seconds: video.duration_seconds,
          products: Array(video.products).filter_map { |p| p["name"].presence || p["id"] if p.is_a?(Hash) },
          views: metrics["views"],
          likes: metrics["likes"],
          items_sold: metrics["items_sold"],
          gmv: gmv.is_a?(Hash) ? gmv["amount"] : gmv,
          metrics_window: metrics["window"],
          tiktok_url: video.tiktok_url,
          download_status: downloaded ? "downloaded" : video.download_status,
          download_url: video.download_link,
          download_error: video.download_status == "failed" ? video.download_error : nil,
          size_mb: downloaded ? (video.file.blob.byte_size / 1.megabyte.to_f).round(1) : nil
        }
      end

      def last_sync
        log = current_tenant.integration_sync_logs
          .where(action: Integrations::Tiktok::AffiliateVideoSyncService::ACTION)
          .order(created_at: :desc).first
        log && { status: log.status, started_at: log.started_at, finished_at: log.finished_at }
      end

      def pagination_meta(paged)
        {
          current_page: paged.current_page,
          total_pages: paged.total_pages,
          total_count: paged.total_count,
          per_page: paged.limit_value
        }
      end
    end
  end
end
