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
          created_at:             source.created_at
        }
      end

      def show_json(source)
        index_json(source).merge(settings: source.settings)
      end
    end
  end
end
