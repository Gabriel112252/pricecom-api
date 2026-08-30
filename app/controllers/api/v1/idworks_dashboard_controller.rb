module Api
  module V1
    # Leitura da aba "idworks" além da conciliação já existente (ver
    # ReconciliationOverviewController) — receita/pedidos/produtos/canal no
    # período, com corte opcional por loja (Hidrabene x Anasol).
    class IdworksDashboardController < ApplicationController
      def index
        period_from, period_to = period_params

        # Esta tela dispara várias agregações grandes (orders/order_items/
        # products + espelho idworks) no mesmo request. Em PostgreSQL dentro
        # de container, planos paralelos podem abrir segmentos DSM em /dev/shm;
        # com o shm padrão do Docker isso já derrubou a tela com PG::DiskFull
        # ("could not resize shared memory segment ... No space left on device").
        #
        # Desabilitamos paralelismo SOMENTE para este request e dentro de uma
        # transação. SET LOCAL volta automaticamente ao valor original no fim
        # da transação, sem contaminar o pool de conexões nem o restante da API.
        result = ApplicationRecord.transaction(requires_new: true) do
          ActiveRecord::Base.connection.execute("SET LOCAL max_parallel_workers_per_gather = 0")

          Idworks::StoreAwareDashboardStatsService.call(
            tenant: current_tenant,
            period_from: period_from,
            period_to: period_to,
            loja: params[:loja]
          )
        end

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
