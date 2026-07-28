module Integrations
  module Tiktok
    # Dispatcher do cron (config/schedule.yml, DESLIGADO por ora — ver
    # ShopAnalyticsSyncService): um ShopAnalyticsSyncJob por credencial
    # TikTok ativa. Dado muda pouco (é um agregado de 30 dias corridos),
    # então 1x/dia é suficiente quando isso for ligado — nada de sweep de
    # alta frequência como os pollers de pedido.
    class ShopAnalyticsSyncSchedulerJob < ApplicationJob
      queue_as :integrations

      def perform
        ChannelCredential.active.where(channel: "tiktok").find_each do |credential|
          ShopAnalyticsSyncJob.perform_later(credential.id, trigger: "scheduled")
        end
      end
    end
  end
end
