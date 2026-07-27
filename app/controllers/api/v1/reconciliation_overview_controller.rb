module Api
  module V1
    # Leitura da aba "Reconciliação idworks" — só lê ReconciliationItem já
    # persistido (o gatilho de recomputar é IdworksController#reconcile, e
    # o job semanal Integrations::Idworks::ScheduleOrderReconciliationJob).
    # Mesmo padrão de endpoint dedicado de StockOverviewController: uma
    # tabela por SKU não cabe no payload único de dashboard/summary.
    class ReconciliationOverviewController < ApplicationController
      def index
        period_from, period_to = period_params
        threshold_pct = params[:threshold_pct].present? ? params[:threshold_pct].to_f : Reconciliation::OrderReconciliationService::DEFAULT_THRESHOLD_PCT

        items = current_tenant.reconciliation_items
          .for_period(period_from, period_to)
          .order(:sku)

        render json: {
          items: items.map { |item| item_json(item, threshold_pct) },
          period: { from: period_from.iso8601, to: period_to.iso8601 },
          threshold_pct: threshold_pct
        }
      rescue ArgumentError
        render json: { errors: [ "Datas inválidas" ] }, status: :unprocessable_entity
      end

      private

      def period_params
        from = params[:from].present? ? Date.parse(params[:from]) : 1.week.ago.to_date
        to   = params[:to].present? ? Date.parse(params[:to]) : Date.current
        [ from, to ]
      end

      def item_json(item, threshold_pct)
        {
          id:                   item.id,
          sku:                  item.sku,
          product_name:         item.product_name,
          idworks_qty:          item.idworks_qty,
          pricecom_qty:         item.pricecom_qty,
          diff_qty:             item.diff_qty,
          diff_pct:             item.diff_pct,
          unmatched_in_idworks: item.unmatched_in_idworks?,
          divergent:            item.divergent?(threshold_pct)
        }
      end
    end
  end
end
