module Integrations
  module Yampi
    class CartsPollingJob < ApplicationJob
      queue_as :integrations

      def perform(channel_credential_id, trigger: "scheduled")
        channel_credential = ChannelCredential.find_by(id: channel_credential_id)
        return unless channel_credential

        result = Integrations::Yampi::CartsPollingService.call(channel_credential, trigger: trigger)
        return unless result.rate_limited?

        self.class.set(wait: result.retry_after.to_i.seconds).perform_later(channel_credential.id, trigger: "rate_limit_retry")
      end
    end
  end
end
