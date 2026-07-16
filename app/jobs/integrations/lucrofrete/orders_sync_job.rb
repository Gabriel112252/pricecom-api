module Integrations
  module Lucrofrete
    class OrdersSyncJob < ApplicationJob
      queue_as :integrations

      def perform(channel_credential_id, mode: "incremental", start_date: nil, end_date: nil, trigger: "scheduled")
        channel_credential = ChannelCredential.find_by(id: channel_credential_id)
        return unless channel_credential

        Integrations::Lucrofrete::OrdersSyncService.call(
          channel_credential,
          mode: mode,
          start_date: start_date,
          end_date: end_date,
          trigger: trigger
        )
      end
    end
  end
end
