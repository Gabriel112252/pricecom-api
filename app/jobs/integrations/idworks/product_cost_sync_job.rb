module Integrations
  module Idworks
    # Runs one idworks Integration's product cost sync. Used both by the
    # manual "Sincronizar agora" endpoint (IdworksController#sync) and by
    # the scheduled dispatcher below.
    class ProductCostSyncJob < ApplicationJob
      queue_as :integrations

      def perform(integration_id)
        integration = Integration.find_by(id: integration_id)
        return unless integration

        Integrations::Idworks::ProductCostSyncService.call(integration)
      end
    end
  end
end
