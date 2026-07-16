module Integrations
  module Lucrofrete
    class OrdersSyncSchedulerJob < ApplicationJob
      queue_as :integrations

      # Recurring LucroFrete real freight sync. The raw quote-log polling
      # remains available for analysis, but the 15min scheduler must use
      # reports/orders because LucroFrete already resolves the order match.
      def perform
        ChannelCredential
          .active
          .where(channel: "lucrofrete")
          .find_each do |channel_credential|
            next unless DataSourceConfig.source_for(channel_credential.tenant, "freight") == "lucrofrete"

            OrdersSyncJob.perform_later(channel_credential.id, mode: "incremental", trigger: "scheduled")
          end
      end
    end
  end
end
