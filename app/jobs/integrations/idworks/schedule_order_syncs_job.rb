module Integrations
  module Idworks
    # The recurring entrypoint (see config/schedule.yml, loaded by
    # sidekiq-cron): fans out one OrderSyncJob (default 2h incremental
    # window, see OrderSyncService::DEFAULT_WINDOW) per connected idworks
    # Integration whose tenant has "freight" pointed at idworks.
    class ScheduleOrderSyncsJob < ApplicationJob
      queue_as :integrations

      def perform
        Integration.where(provider: "idworks", status: "connected").find_each do |integration|
          next unless DataSourceConfig.source_for(integration.tenant, "freight") == "idworks"

          OrderSyncJob.perform_later(integration.id)
        end
      end
    end
  end
end
