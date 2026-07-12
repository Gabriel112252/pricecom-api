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
        rescue Integrations::AuthenticationError
          integration.update!(status: "error")
          return render json: { errors: [ "E-mail ou senha do idworks inválidos." ] }, status: :unprocessable_entity
        rescue Integrations::ApiError, Integrations::RateLimitError => e
          integration.update!(status: "error")
          return render json: { errors: [ "Não foi possível conectar ao idworks agora: #{e.message}" ] }, status: :unprocessable_entity
        end

        render json: integration_json(integration)
      end

      # POST /api/v1/integrations/idworks/sync
      # Runs both the product cost pull and the order freight sync in one
      # call — the two are independent services internally
      # (Integrations::Idworks::ProductCostSyncService /
      # Integrations::Idworks::OrderSyncService) but there's only one "sync
      # idworks" action from the user's point of view. This is also what
      # the manual "Sincronizar agora" button calls, same services the
      # scheduled jobs (Idworks::ProductCostSyncJob / Idworks::OrderSyncJob)
      # use — see config/schedule.yml.
      def sync
        integration = current_tenant.integrations.find_by(provider: "idworks")

        if integration.nil? || integration.status != "connected"
          return render json: { error: "idworks ainda não está conectado" }, status: :unprocessable_entity
        end

        cost_result  = Integrations::Idworks::ProductCostSyncService.call(integration)
        order_result = Integrations::Idworks::OrderSyncService.call(integration, from: 24.hours.ago)

        render json: {
          success:               !cost_result.error? && !order_result.error?,
          products_synced_count: cost_result.synced_count,
          orders_synced_count:   order_result.synced_count,
          products_received_count: cost_result.metadata[:received_count] || cost_result.metadata["received_count"],
          products_found_by_sku_count: cost_result.metadata[:matched_count] || cost_result.metadata["matched_count"],
          products_updated_count: cost_result.metadata[:product_updated_count] || cost_result.metadata["product_updated_count"],
          product_order_items_updated_count: cost_result.metadata[:order_items_updated_count] || cost_result.metadata["order_items_updated_count"],
          products_ignored_count: cost_result.metadata[:ignored_count] || cost_result.metadata["ignored_count"],
          products_ignored_reason_counts: cost_result.metadata[:ignored_reason_counts] || cost_result.metadata["ignored_reason_counts"],
          products_matched_examples: cost_result.metadata[:matched_examples] || cost_result.metadata["matched_examples"],
          products_error_count: cost_result.metadata[:error_count] || cost_result.metadata["error_count"],
          order_freights_received_count: order_result.metadata[:received_count] || order_result.metadata["received_count"],
          order_freights_found_count: order_result.metadata[:found_count] || order_result.metadata["found_count"],
          order_freights_updated_count: order_result.metadata[:updated_count] || order_result.metadata["updated_count"],
          order_freights_recalculated_count: order_result.metadata[:recalculated_count] || order_result.metadata["recalculated_count"],
          order_freights_ignored_count: order_result.metadata[:ignored_count] || order_result.metadata["ignored_count"],
          order_freights_ignored_reason_counts: order_result.metadata[:ignored_reason_counts] || order_result.metadata["ignored_reason_counts"],
          order_freights_ignored_examples: order_result.metadata[:ignored] || order_result.metadata["ignored"],
          order_freights_matched_examples: order_result.metadata[:matched_examples] || order_result.metadata["matched_examples"],
          orders_recalculated_count: (cost_result.metadata[:orders_recalculated_count] || cost_result.metadata["orders_recalculated_count"]).to_i +
            (order_result.metadata[:recalculated_count] || order_result.metadata["recalculated_count"]).to_i,
          error_message:         [ cost_result.error_message, order_result.error_message ].compact.first
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
