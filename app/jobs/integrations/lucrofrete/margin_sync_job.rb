module Integrations
  module Lucrofrete
    class MarginSyncJob < ApplicationJob
      queue_as :integrations

      def perform(channel_credential_id, days: nil, trigger: "scheduled")
        channel_credential = ChannelCredential.find_by(id: channel_credential_id)
        return unless channel_credential

        Integrations::Lucrofrete::MarginSyncService.call(channel_credential, days: days, trigger: trigger)
      end
    end
  end
end
