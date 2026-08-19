module Api
  module V1
    # Leitura da aba "idworks" além da conciliação já existente (ver
    # ReconciliationOverviewController) — receita/pedidos/produtos/canal no
    # período, com corte opcional por loja (Hidrabene x Anasol). Toda a
    # agregação vive em Idworks::DashboardStatsService.
    class IdworksDashboardController < ApplicationController
      def index
        period_from, period_to = period_params

        result = Idworks::DashboardStatsService.call(
          tenant: current_tenant,
          period_from: period_from,
          period_to: period_to,
          loja: params[:loja]
        )

        render json: {
          period:             { from: period_from.iso8601, to: period_to.iso8601 },
          loja:               params[:loja].presence,
          revenue_total:      result.revenue_total,
          orders_count:       result.orders_count,
          average_ticket:     result.average_ticket,
          revenue_by_loja:    result.revenue_by_loja,
          orders_timeseries:  result.orders_timeseries,
          top_products:       result.top_products,
          channel_breakdown:  result.channel_breakdown,
          real_skus_sold:     result.real_skus_sold,
          idworks_revenue_total: result.idworks_revenue_total,
          idworks_orders_count: result.idworks_orders_count,
          idworks_average_ticket: result.idworks_average_ticket,
          idworks_revenue_by_loja: result.idworks_revenue_by_loja,
          idworks_orders_timeseries: result.idworks_orders_timeseries,
          idworks_channel_breakdown: result.idworks_channel_breakdown
        }
      rescue ArgumentError
        render json: { errors: [ "Datas inválidas" ] }, status: :unprocessable_entity
      end

      private

      def period_params
        from = params[:start_date].presence || params[:from].presence
        to   = params[:end_date].presence || params[:to].presence
        [ from.present? ? Date.parse(from) : 1.week.ago.to_date, to.present? ? Date.parse(to) : Date.current ]
      end
    end
  end
end
