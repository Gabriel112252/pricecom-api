module Integrations
  module Idworks
    # Runs one idworks Integration's incremental order/freight sync. Used
    # both by the manual "Sincronizar agora" endpoint
    # (IdworksController#sync, with a wider one-off window) and by the
    # scheduled dispatcher below (tight, frequent window).
    class OrderSyncJob < ApplicationJob
      queue_as :integrations

      def perform(integration_id)
        integration = Integration.find_by(id: integration_id)
        return unless integration

        Integrations::Idworks::OrderSyncService.call(integration)
      end
    end
  end
end
