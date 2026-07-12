module Api
  module V1
    class FinancialSourcesController < ApplicationController
      def index
        sources = apply_filters(current_tenant.financial_sources.includes(:channel, :integration))
          .order(name: :asc)

        render json: sources.map { |s| index_json(s) }
      end

      def show
        source = current_tenant.financial_sources
          .includes(:channel, :integration)
          .find(params[:id])

        render json: show_json(source)
      end

      private

      def apply_filters(scope)
        scope = scope.where(provider:    params[:provider])    if params[:provider].present?
        scope = scope.where(source_type: params[:source_type]) if params[:source_type].present?
        scope = scope.where(status:      params[:status])      if params[:status].present?
        scope = scope.where(active: ActiveModel::Type::Boolean.new.cast(params[:active])) if params[:active].present?

        scope
      end

      def index_json(source)
        {
          id:                     source.id,
          provider:               source.provider,
          name:                   source.name,
          source_type:            source.source_type,
          status:                 source.status,
          active:                 source.active,
          channel_id:             source.channel_id,
          channel_name:           source.channel&.name,
          integration_id:         source.integration_id,
          integration_name:       source.integration&.name,
          credentials_configured: source.credentials_configured?,
          last_synced_at:         source.last_synced_at,
          recent_logs:            recent_logs_for(source),
          created_at:             source.created_at
        }
      end

      def show_json(source)
        index_json(source).merge(settings: source.settings)
      end

      def recent_logs_for(source)
        IntegrationSyncLog
          .where(tenant: current_tenant, action: "pagarme_settlement_sync")
          .where("metadata->>'financial_source_id' = ?", source.id.to_s)
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
          synced_count:  log.metadata["created_count"].to_i + log.metadata["updated_count"].to_i,
          received_count: nil,
          updated_count: log.metadata["updated_count"],
          ignored_count: log.metadata["skipped_count"],
          started_at:    log.started_at,
          finished_at:   log.finished_at
        }
      end
    end
  end
end
