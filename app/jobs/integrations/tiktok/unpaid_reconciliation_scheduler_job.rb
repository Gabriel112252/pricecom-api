module Integrations
  module Tiktok
    class UnpaidReconciliationSchedulerJob < ApplicationJob
      queue_as :integrations

      def perform
        ChannelCredential
          .active
          .where(channel: "tiktok", polling_enabled: true)
          .find_each do |channel_credential|
            UnpaidReconciliationJob.perform_later(channel_credential.id, trigger: "scheduled")
          end
      end
    end
  end
end
