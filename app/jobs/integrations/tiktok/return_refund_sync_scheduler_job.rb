module Integrations
  module Tiktok
    # Dispatcher do cron (config/schedule.yml): um ReturnRefundSyncJob por
    # credencial TikTok ativa, varrendo a janela padrão de
    # ReturnRefundSyncService::DEFAULT_WINDOW_DAYS a cada execução — mesmo
    # padrão de "sweep" que UnpaidReconciliationSchedulerJob usa para
    # reconciliação, mas sem lock de credencial dedicado: diferente do
    # backfill financeiro por statement, aqui não há paginação de estado
    # entre execuções pra proteger.
    class ReturnRefundSyncSchedulerJob < ApplicationJob
      queue_as :integrations

      def perform
        ChannelCredential.active.where(channel: "tiktok").find_each do |credential|
          ReturnRefundSyncJob.perform_later(credential.id, trigger: "scheduled")
        end
      end
    end
  end
end
