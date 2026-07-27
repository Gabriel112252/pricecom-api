module Integrations
  module Idworks
    # O dispatcher recorrente (ver config/schedule.yml, carregado por
    # sidekiq-cron): fana um OrderReconciliationJob por Integration idworks
    # conectada cujo tenant tem "order_reconciliation" apontado pra idworks
    # — igual ScheduleStockSyncsJob. Compara sempre a última semana corrida
    # (segunda a segunda), não um período fixo de calendário.
    class ScheduleOrderReconciliationJob < ApplicationJob
      queue_as :integrations

      def perform
        Integration.where(provider: "idworks", status: "connected").find_each do |integration|
          next unless DataSourceConfig.source_for(integration.tenant, "order_reconciliation") == "idworks"

          OrderReconciliationJob.perform_later(integration.id, 1.week.ago.to_date.iso8601, Date.current.iso8601)
        end
      end
    end
  end
end
