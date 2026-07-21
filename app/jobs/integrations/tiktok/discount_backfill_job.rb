module Integrations
  module Tiktok
    class DiscountBackfillJob < ApplicationJob
      queue_as :integrations

      def perform(tenant_id:)
        tenant = Tenant.find_by(id: tenant_id)
        return unless tenant

        credential = tenant.channel_credentials.find_by(channel: "tiktok")
        return unless credential

        Integrations::Tiktok::DiscountBackfillService.call(credential)
      end
    end
  end
end
