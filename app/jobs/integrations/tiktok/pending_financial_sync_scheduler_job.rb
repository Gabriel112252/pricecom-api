module Integrations
  module Tiktok
    # Dispatcher for the proposed 15-minute safety-net cron. The cron entry is
    # intentionally commented out until the pilot is approved.
    class PendingFinancialSyncSchedulerJob < ApplicationJob
      queue_as :integrations

      def perform
        ChannelCredential.active.where(channel: "tiktok").find_each do |credential|
          PendingFinancialSyncJob.perform_later(credential.id)
        end
      end
    end
  end
end
