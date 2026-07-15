module Integrations
  module Tiktok
    class OrdersPollingSchedulerJob < ApplicationJob
      queue_as :integrations

      def perform
        ChannelCredential
          .active
          .where(channel: "tiktok", polling_enabled: true)
          .find_each do |channel_credential|
            next if polling_locked?(channel_credential)

            OrdersPollingJob.perform_later(channel_credential.id, trigger: "scheduled")
          end
      end

      private

      def polling_locked?(channel_credential)
        Integrations::OrdersPollingLock.new(channel_credential).locked?
      rescue => e
        Rails.logger.warn("[Integrations::Tiktok::OrdersPollingSchedulerJob] lock check failed for channel_credential_id=#{channel_credential.id}: #{e.message}")
        false
      end
    end
  end
end
