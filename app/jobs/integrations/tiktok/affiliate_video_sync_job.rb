module Integrations
  module Tiktok
    # Refreshes the target-collaboration creators (AffiliateSyncService) and
    # then their videos (AffiliateVideoSyncService) for one TikTok
    # credential. The creator refresh comes first because the video sync only
    # keeps videos from creators it already knows; if that refresh is busy
    # (another run holds AffiliateSyncLock) or fails, the video sync still
    # runs against the creators synced last time.
    #
    # The creator refresh walks every target collaboration (139 on Hidrabene,
    # ~5 minutes), so it is skipped when one already succeeded for this
    # credential within CREATORS_FRESH_FOR.
    class AffiliateVideoSyncJob < ApplicationJob
      queue_as :integrations

      DEFAULT_RATE_LIMIT_WAIT = 2.minutes
      MIN_RATE_LIMIT_WAIT = 1.minute
      MAX_RATE_LIMIT_WAIT = 30.minutes
      CREATORS_FRESH_FOR = 6.hours

      retry_on Faraday::Error, wait: 30.seconds, attempts: 3
      retry_on ActiveRecord::Deadlocked, wait: 5.seconds, attempts: 3

      def perform(channel_credential_id, days_back: AffiliateVideoSyncService::DEFAULT_DAYS_BACK, sync_creators: true)
        channel_credential = ChannelCredential.find_by(id: channel_credential_id)
        return unless channel_credential

        refresh_creators(channel_credential) if sync_creators && !creators_fresh?(channel_credential)
        AffiliateVideoSyncService.call(channel_credential, days_back: days_back)
      rescue Integrations::RateLimitError => e
        self.class.set(wait: rate_limit_wait_seconds(e).seconds)
          .perform_later(channel_credential_id, days_back: days_back, sync_creators: false)
      end

      private

      def creators_fresh?(channel_credential)
        IntegrationSyncLog
          .where(tenant_id: channel_credential.tenant_id, action: AffiliateSyncService::ACTION, status: "success")
          .where("finished_at > ?", CREATORS_FRESH_FOR.ago)
          .where("metadata ->> 'channel_credential_id' = ?", channel_credential.id.to_s)
          .exists?
      end

      def refresh_creators(channel_credential)
        AffiliateSyncService.call(channel_credential, run_id: job_id)
      rescue AffiliateSyncLock::LockBusyError, AffiliateSyncLock::LockLostError, Integrations::RateLimitError => e
        Rails.logger.warn("[AffiliateVideoSyncJob] criadoras não atualizadas (credential=#{channel_credential.id}): #{e.class}: #{e.message}")
      end

      def rate_limit_wait_seconds(error)
        retry_after = error.retry_after.to_f
        retry_after = DEFAULT_RATE_LIMIT_WAIT.to_i unless retry_after.positive?
        retry_after.clamp(MIN_RATE_LIMIT_WAIT.to_i, MAX_RATE_LIMIT_WAIT.to_i)
      end
    end
  end
end
