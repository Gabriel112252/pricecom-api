module Integrations
  # Runs one ChannelCredential's product sync. Used both by the manual
  # "Sincronizar agora" endpoint and by the scheduled dispatcher below.
  class ProductSyncJob < ApplicationJob
    queue_as :integrations

    def perform(channel_credential_id)
      channel_credential = ChannelCredential.find_by(id: channel_credential_id)
      return unless channel_credential

      Integrations::ProductSyncService.call(channel_credential)
    end
  end
end
