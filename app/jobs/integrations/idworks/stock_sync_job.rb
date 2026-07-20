module Integrations
  module Idworks
    # Runs one idworks Integration's stock sync. Used by the scheduled
    # dispatcher below (see ScheduleStockSyncsJob).
    class StockSyncJob < ApplicationJob
      queue_as :integrations

      def perform(integration_id)
        integration = Integration.find_by(id: integration_id)
        return unless integration

        Integrations::Idworks::StockSyncService.call(integration)
      end
    end
  end
end
