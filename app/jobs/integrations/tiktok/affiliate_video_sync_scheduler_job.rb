module Integrations
  module Tiktok
    # Dispatcher for config/schedule.yml's tiktok_affiliate_video_sync_dispatch
    # (commented out until the first manual run is checked against Hidrabene —
    # same rule as the affiliate creator sync). One AffiliateVideoSyncJob per
    # active TikTok credential.
    class AffiliateVideoSyncSchedulerJob < ApplicationJob
      queue_as :integrations

      def perform
        ChannelCredential.active.where(channel: "tiktok").find_each do |credential|
          AffiliateVideoSyncJob.perform_later(credential.id)
        end
      end
    end
  end
end
