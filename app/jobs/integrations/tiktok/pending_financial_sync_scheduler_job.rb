module Integrations
  module Tiktok
    # Dispatcher do cron de 15 minutos (config/schedule.yml, ativado
    # definitivamente em 2026-07-24): um PendingFinancialSyncJob por
    # credencial TikTok ativa, em lote pequeno pra não esbarrar no rate
    # limit da Finance API — 1 pedido = 1 chamada de
    # statement_transactions. O próprio job agenda continuações quando
    # sobram pendências, e o FinancialSyncLock impede duas execuções
    # concorrentes por credencial.
    class PendingFinancialSyncSchedulerJob < ApplicationJob
      queue_as :integrations

      SCHEDULED_BATCH_SIZE = Integer(ENV.fetch("TIKTOK_PENDING_FINANCIAL_SCHEDULED_BATCH_SIZE", "25"))

      def perform
        ChannelCredential.active.where(channel: "tiktok").find_each do |credential|
          PendingFinancialSyncJob.perform_later(credential.id, batch_size: SCHEDULED_BATCH_SIZE)
        end
      end
    end
  end
end
