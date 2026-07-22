module Integrations
  # The recurring entrypoint (see config/schedule.yml, loaded by
  # sidekiq-cron): fans out one ProductSyncJob per active ChannelCredential,
  # across every tenant. Keeping the cron target a lightweight dispatcher
  # (rather than scheduling N per-credential cron entries) means newly
  # connected channels start syncing on the very next tick with no schedule
  # changes required.
  class ScheduleProductSyncsJob < ApplicationJob
    queue_as :integrations

    def perform
      supported_channels = Integrations::ProductSyncService::ADAPTERS.keys

      ChannelCredential
        .active
        .where(channel: supported_channels)
        .find_each do |channel_credential|
          ProductSyncJob.perform_later(channel_credential.id)
        end
    end
  end
end
