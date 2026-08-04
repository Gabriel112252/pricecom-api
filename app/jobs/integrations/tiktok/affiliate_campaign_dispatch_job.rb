module Integrations
  module Tiktok
    class AffiliateCampaignDispatchJob < ApplicationJob
      queue_as :integrations

      retry_on Faraday::Error, wait: 30.seconds, attempts: 3
      retry_on ActiveRecord::Deadlocked, wait: 5.seconds, attempts: 3

      def perform(campaign_id)
        campaign = AffiliateCampaign.find_by(id: campaign_id)
        return unless campaign

        result = Integrations::Tiktok::AffiliateCampaignDispatchService.call(campaign)
        schedule_continuation(campaign_id, result) if result.next_retry_at.present?
      end

      private

      def schedule_continuation(campaign_id, result)
        wait_seconds = result.next_retry_at.to_i - Time.current.to_i
        wait_seconds = Integrations::Tiktok::AffiliateCampaignDispatchService::RECENT_BASE_DELAY.to_i if wait_seconds <= 0
        self.class.set(wait: wait_seconds.seconds).perform_later(campaign_id)
      end
    end
  end
end
