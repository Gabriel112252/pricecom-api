module Integrations
  module Idworks
    # The recurring entrypoint (see config/schedule.yml, loaded by
    # sidekiq-cron): fans out one StockSyncJob per connected idworks
    # Integration whose tenant has "stock" pointed at idworks — skipping
    # tenants that repointed stock elsewhere (or never configured it)
    # avoids an idworks sign-in call that would just be thrown away
    # (StockSyncService itself would also skip, but there's no reason to
    # even enqueue the job). Runs more often than the cost sync (6h) —
    # stock going negative is time-sensitive in a way cost drift isn't.
    class ScheduleStockSyncsJob < ApplicationJob
      queue_as :integrations

      def perform
        Integration.where(provider: "idworks", status: "connected").find_each do |integration|
          next unless DataSourceConfig.source_for(integration.tenant, "stock") == "idworks"

          StockSyncJob.perform_later(integration.id)
        end
      end
    end
  end
end
