module Integrations
  module Lucrofrete
    class QuotesPollingSchedulerJob < ApplicationJob
      queue_as :integrations

      # Sem filtro de polling_enabled: essa flag é a chave liga/desliga do
      # polling de PEDIDOS Yampi (rate-limit-sensível); a credencial
      # LucroFrete conectada e ativa já é o opt-in do polling de cotações.
      def perform
        ChannelCredential
          .active
          .where(channel: "lucrofrete")
          .find_each do |channel_credential|
            QuotesPollingJob.perform_later(channel_credential.id, trigger: "scheduled")
          end
      end
    end
  end
end
