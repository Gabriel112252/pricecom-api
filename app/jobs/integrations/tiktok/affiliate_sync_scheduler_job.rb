module Integrations
  module Tiktok
    # Dispatcher for config/schedule.yml's tiktok_affiliate_sync_dispatch
    # (currently commented out — see that file). One AffiliateSyncJob per
    # active TikTok credential; AffiliateSyncLock prevents concurrent runs
    # per credential.
    class AffiliateSyncSchedulerJob < ApplicationJob
      queue_as :integrations

      def perform
        ChannelCredential.active.where(channel: "tiktok").find_each do |credential|
          AffiliateSyncJob.perform_later(credential.id)
        end
      end
    end
  end
end
