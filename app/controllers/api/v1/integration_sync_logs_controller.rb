module Api
  module V1
    class IntegrationSyncLogsController < ApplicationController
      PER_PAGE_DEFAULT = 50
      PER_PAGE_MAX     = 100

      def index
        base  = apply_filters(current_tenant.integration_sync_logs)
        logs  = base.includes(:integration)
                    .order("integration_sync_logs.created_at DESC")

        per   = [[params.fetch(:per_page, PER_PAGE_DEFAULT).to_i, 1].max, PER_PAGE_MAX].min
        paged = logs.page(params[:page]).per(per)

        render json: {
          logs: paged.map { |l| index_json(l) },
          meta: pagination_meta(paged)
        }
      end

      def show
        log = current_tenant.integration_sync_logs
          .includes(:integration)
          .find(params[:id])

        render json: show_json(log)
      end

      private

      # Filtros disponíveis: integration_id, direction, status, log_action,
      #                      external_id, external_type, date_from, date_to
      # Nota: usa log_action (não action) — params[:action] é reservado pelo Rails
      def apply_filters(scope)
        scope = scope.where(integration_id: params[:integration_id]) if params[:integration_id].present?
        scope = scope.where(direction:      params[:direction])      if params[:direction].present?
        scope = scope.where(status:         params[:status])         if params[:status].present?
        scope = scope.where(action:         params[:log_action])     if params[:log_action].present?
        scope = scope.where(external_id:    params[:external_id])    if params[:external_id].present?
        scope = scope.where(external_type:  params[:external_type])  if params[:external_type].present?
        scope = scope.where("integration_sync_logs.created_at >= ?", params[:date_from]) if params[:date_from].present?
        scope = scope.where("integration_sync_logs.created_at <= ?", params[:date_to])   if params[:date_to].present?
        scope
      end

      def index_json(log)
        {
          id:               log.id,
          integration_id:   log.integration_id,
          integration_name: log.integration&.name,
          direction:        log.direction,
          action:           log.action,
          status:           log.status,
          external_id:      log.external_id,
          external_type:    log.external_type,
          error_message:    log.error_message,
          duration_ms:      log.duration_ms,
          started_at:       log.started_at,
          finished_at:      log.finished_at,
          created_at:       log.created_at
        }
      end

      def show_json(log)
        index_json(log).merge(
          metadata:         log.metadata,
          request_payload:  log.request_payload,
          response_payload: log.response_payload
        )
      end

      def pagination_meta(paged)
        {
          current_page: paged.current_page,
          total_pages:  paged.total_pages,
          total_count:  paged.total_count,
          per_page:     paged.limit_value
        }
      end
    end
  end
end
