module Integrations
  module Lucrofrete
    class MarginSyncSchedulerJob < ApplicationJob
      queue_as :integrations

      def perform
        ChannelCredential
          .active
          .where(channel: "lucrofrete")
          .find_each do |channel_credential|
            MarginSyncJob.perform_later(channel_credential.id, trigger: "scheduled")
          end
      end
    end
  end
end
