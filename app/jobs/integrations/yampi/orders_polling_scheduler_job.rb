module Integrations
  module Yampi
    class OrdersPollingSchedulerJob < ApplicationJob
      queue_as :integrations

      def perform
        ChannelCredential
          .active
          .where(channel: "yampi", polling_enabled: true)
          .find_each do |channel_credential|
            OrdersPollingJob.perform_later(channel_credential.id, trigger: "scheduled")
          end
      end
    end
  end
end
