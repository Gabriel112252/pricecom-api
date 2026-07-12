module Integrations
  module Idworks
    # The recurring entrypoint (see config/schedule.yml, loaded by
    # sidekiq-cron): fans out one ProductCostSyncJob per connected idworks
    # Integration whose tenant has "cost" pointed at idworks — skipping
    # tenants that repointed cost elsewhere avoids an idworks sign-in call
    # that would just be thrown away (ProductCostSyncService itself would
    # also skip, but there's no reason to even enqueue the job).
    class ScheduleProductCostSyncsJob < ApplicationJob
      queue_as :integrations

      def perform
        Integration.where(provider: "idworks", status: "connected").find_each do |integration|
          next unless DataSourceConfig.source_for(integration.tenant, "cost") == "idworks"

          ProductCostSyncJob.perform_later(integration.id)
        end
      end
    end
  end
end
