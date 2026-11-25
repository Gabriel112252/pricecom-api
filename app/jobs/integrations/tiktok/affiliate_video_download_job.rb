module Integrations
  module Tiktok
    # Downloads one AffiliateVideo (AffiliateVideoDownloadService). Queued by
    # AffiliateVideoSyncService for new videos and by the
    # baixar_video_afiliada MCP tool on demand.
    class AffiliateVideoDownloadJob < ApplicationJob
      queue_as :integrations

      retry_on Integrations::RateLimitError, wait: 2.minutes, attempts: 5

      def perform(affiliate_video_id)
        video = AffiliateVideo.find_by(id: affiliate_video_id)
        return unless video
        return if video.downloaded?

        AffiliateVideoDownloadService.call(video)
      end
    end
  end
end
