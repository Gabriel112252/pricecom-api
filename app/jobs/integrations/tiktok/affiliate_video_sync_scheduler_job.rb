module Integrations
  module Tiktok
    # Dispatcher for config/schedule.yml's tiktok_affiliate_video_sync_dispatch
    # (daily at 7:00 São Paulo since 2026-11-25, after the first real run on
    # Hidrabene came out clean). One AffiliateVideoSyncJob per active TikTok
    # credential.
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
