module Api
  module V1
    # ERP integration (idworks) — real product cost/tax and invoice
    # (NF) matching. Separate from ChannelCredentialsController since
    # idworks isn't a sales channel; it's modeled as an Integration
    # (provider: "idworks"), same as the generic Integrations::* records.
    class IdworksController < ApplicationController
      before_action :require_admin!

      # POST /api/v1/integrations/idworks/connect
      def connect
        integration = current_tenant.integrations.find_or_initialize_by(provider: "idworks", name: "idworks")
        integration.credentials = credential_params
        integration.status = "disconnected"

        unless integration.save
          return render json: { errors: integration.errors.full_messages }, status: :unprocessable_entity
        end

        # cost/tax/freight default to idworks the first time it's connected —
        # DataSourceConfig lets a tenant repoint any of these later without
        # this ever running again (find_or_create, never overwrites).
        DataSourceConfig.ensure_defaults_for_source!(current_tenant, "idworks")

        begin
          Integrations::IdworksAdapter.new(integration.credentials).authenticate
          integration.update!(status: "connected")
        rescue Integrations::AuthenticationError, Integrations::ApiError, Integrations::RateLimitError => e
          integration.update!(status: "error")
          return render json: { errors: [ e.message ] }, status: :unprocessable_entity
        end

        render json: integration_json(integration)
      end

      # POST /api/v1/integrations/idworks/sync
      # Runs both the product cost/tax pull and the invoice (NF) matching
      # pass in one call — the two are independent services internally
      # (Integrations::Idworks::ProductCostSyncService /
      # Integrations::InvoiceSyncService) but there's only one "sync idworks"
      # action from the user's point of view.
      def sync
        integration = current_tenant.integrations.find_by(provider: "idworks")

        if integration.nil? || integration.status == "disconnected"
          return render json: { error: "idworks ainda não está conectado" }, status: :unprocessable_entity
        end

        cost_result    = Integrations::Idworks::ProductCostSyncService.call(integration)
        invoice_result = Integrations::InvoiceSyncService.call(integration)

        render json: {
          success:                cost_result.success? && invoice_result.success?,
          products_synced_count:  cost_result.synced_count,
          invoices_synced_count:  invoice_result.synced_count,
          error_message:          [ cost_result.error_message, invoice_result.error_message ].compact.first
        }
      end

      private

      def credential_params
        params.require(:credentials).permit!.to_h
      end

      def integration_json(integration)
        {
          id:             integration.id,
          provider:       integration.provider,
          status:         integration.status,
          last_synced_at: integration.last_synced_at
        }
      end
    end
  end
end
