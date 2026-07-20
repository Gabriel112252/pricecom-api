module Api
  module V1
    # Read/act on StockAlert events raised by StockAlerts::EvaluationService.
    # No dedicated screen yet (Fase 3) — this API exists now so that screen
    # has something to call.
    class StockAlertsController < ApplicationController
      PER_PAGE_DEFAULT = 50
      PER_PAGE_MAX     = 100

      before_action :require_admin!, only: [ :confirm, :dismiss ]

      def index
        alerts = apply_filters(current_tenant.stock_alerts).order(created_at: :desc)

        per   = [ [ params.fetch(:per_page, PER_PAGE_DEFAULT).to_i, 1 ].max, PER_PAGE_MAX ].min
        paged = alerts.page(params[:page]).per(per)

        render json: {
          stock_alerts: paged.map { |a| alert_json(a) },
          meta: pagination_meta(paged)
        }
      end

      # POST /api/v1/stock_alerts/:id/confirm — runs the suggested
      # replenishment right now. Only valid from awaiting_confirmation
      # (the semi_automatic path) — anything else already has a final-ish
      # outcome, so confirming it again would be confusing/wrong.
      def confirm
        alert = current_tenant.stock_alerts.find(params[:id])

        unless alert.status == "awaiting_confirmation"
          return render json: { error: "alerta não está aguardando confirmação (status atual: #{alert.status})" },
            status: :unprocessable_entity
        end

        result = StockAlerts::ReplenishmentExecutorService.call(alert)

        if result.success?
          render json: alert_json(alert.reload)
        else
          render json: { error: result.error_message }, status: :unprocessable_entity
        end
      end

      # POST /api/v1/stock_alerts/:id/dismiss — a human decided not to act
      # on this alert. Only valid while still open (see StockAlert::OPEN_STATUSES) —
      # dismissing an already-executed/failed alert wouldn't mean anything.
      def dismiss
        alert = current_tenant.stock_alerts.find(params[:id])

        unless alert.open?
          return render json: { error: "alerta já foi resolvido (status atual: #{alert.status})" },
            status: :unprocessable_entity
        end

        alert.update!(status: "dismissed")
        render json: alert_json(alert)
      end

      private

      def apply_filters(scope)
        scope = scope.where(status: params[:status]) if params[:status].present?
        scope = scope.where(product_id: params[:product_id]) if params[:product_id].present?
        scope = scope.where(channel: params[:channel]) if params[:channel].present?
        scope
      end

      def alert_json(alert)
        {
          id: alert.id,
          product_id: alert.product_id,
          product_sku: alert.product.sku,
          channel: alert.channel,
          qty_at_trigger: alert.qty_at_trigger,
          target_level: alert.target_level,
          suggested_replenishment_qty: alert.suggested_replenishment_qty,
          automation_level_snapshot: alert.automation_level_snapshot,
          status: alert.status,
          error_message: alert.error_message,
          executed_at: alert.executed_at,
          created_at: alert.created_at
        }
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
