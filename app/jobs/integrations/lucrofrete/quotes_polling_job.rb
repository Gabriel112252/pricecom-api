module Integrations
  module Lucrofrete
    class QuotesPollingJob < ApplicationJob
      queue_as :integrations

      def perform(channel_credential_id, trigger: "scheduled")
        channel_credential = ChannelCredential.find_by(id: channel_credential_id)
        return unless channel_credential

        Integrations::Lucrofrete::QuotesPollingService.call(channel_credential, trigger: trigger)
      end
    end
  end
end
