module Api
  module V1
    class IntegrationsController < ApplicationController
      before_action :set_integration, only: [:show, :update, :destroy]

      def index
        integrations = current_tenant.integrations
          .includes(:channel)
          .order(created_at: :desc)

        integrations = integrations.where(provider: params[:provider]) if params[:provider].present?
        integrations = integrations.where(status: params[:status])     if params[:status].present?
        integrations = integrations.active                             if params[:active] == "true"

        render json: integrations.map { |i| integration_json(i) }
      end

      def show
        render json: integration_json(@integration)
      end

      def create
        integration = current_tenant.integrations.new(integration_params)

        if integration.save
          render json: integration_json(integration), status: :created
        else
          render json: { errors: integration.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def update
        if @integration.update(integration_params)
          render json: integration_json(@integration)
        else
          render json: { errors: @integration.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def destroy
        @integration.destroy
        head :no_content
      end

      private

      def set_integration
        @integration = current_tenant.integrations.find(params[:id])
      end

      def integration_params
        params.permit(
          :provider, :name, :status, :active, :channel_id,
          settings: {},
          credentials: {}
        )
      end

      def integration_json(integration)
        {
          id:                     integration.id,
          provider:               integration.provider,
          name:                   integration.name,
          status:                 integration.status,
          active:                 integration.active,
          channel_id:             integration.channel_id,
          channel_name:           integration.channel&.name,
          settings:               integration.settings,
          credentials_configured: integration.credentials_configured?,
          last_synced_at:         integration.last_synced_at,
          recent_logs:            recent_logs_for(integration),
          created_at:             integration.created_at,
          updated_at:             integration.updated_at
        }
      end

      def recent_logs_for(integration)
        integration.integration_sync_logs
          .order(created_at: :desc)
          .limit(5)
          .map { |log| log_json(log) }
      end

      def log_json(log)
        {
          id:            log.id,
          action:        log.action,
          status:        log.status,
          error_message: log.error_message,
          synced_count:  log.metadata["synced_count"],
          received_count: log.metadata["received_count"],
          updated_count: log.metadata["updated_count"] || log.metadata["product_updated_count"],
          ignored_count: log.metadata["ignored_count"],
          started_at:    log.started_at,
          finished_at:   log.finished_at
        }
      end
    end
  end
end
