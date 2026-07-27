module Integrations
  module Idworks
    # Roda a reconciliação de um tenant pra um período. Usado pelo
    # dispatcher semanal (ver ScheduleOrderReconciliationJob) e também pelo
    # botão "Rodar agora" via IdworksController#reconcile — mesma relação
    # que StockSyncJob/StockSyncService.
    class OrderReconciliationJob < ApplicationJob
      queue_as :integrations

      def perform(integration_id, period_from, period_to)
        integration = Integration.find_by(id: integration_id)
        return unless integration

        Reconciliation::OrderReconciliationService.call(
          tenant: integration.tenant,
          period_from: Date.parse(period_from),
          period_to: Date.parse(period_to)
        )
      end
    end
  end
end
