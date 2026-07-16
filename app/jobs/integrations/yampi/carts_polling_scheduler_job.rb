module Integrations
  module Yampi
    class CartsPollingSchedulerJob < ApplicationJob
      queue_as :integrations

      def perform
        ChannelCredential
          .active
          .where(channel: "yampi", polling_enabled: true)
          .find_each do |channel_credential|
            next if polling_locked?(channel_credential)

            CartsPollingJob.perform_later(channel_credential.id, trigger: "scheduled")
          end
      end

      private

      def polling_locked?(channel_credential)
        Integrations::Yampi::PollingLock.new(channel_credential, scope: "carts_polling").locked?
      rescue => e
        Rails.logger.warn("[Integrations::Yampi::CartsPollingSchedulerJob] lock check failed for channel_credential_id=#{channel_credential.id}: #{e.message}")
        false
      end
    end
  end
end
