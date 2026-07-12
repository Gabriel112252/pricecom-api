module Api
  module V1
    # Lets a tenant see and change which connected source feeds each of the
    # 4 configurable data types (cost/freight/tax/payment_reconciliation) —
    # see DataSourceConfig. Read is open to any authenticated user; changing
    # the source is admin-only, same as connecting an integration.
    class DataSourceConfigsController < ApplicationController
      before_action :require_admin!, only: [ :update ]

      # GET /api/v1/data_source_configs
      # Always returns all 4 data types, even ones with no config row yet
      # (source: nil) — the frontend dropdown needs a full, stable list to
      # render, not just whatever happens to already exist.
      def index
        configs = current_tenant.data_source_configs.index_by(&:data_type)

        render json: DataSourceConfig::DATA_TYPES.map { |data_type|
          config = configs[data_type]
          {
            data_type: data_type,
            source:    config&.source,
            enabled:   config.nil? ? true : config.enabled,
            available_sources: DataSourceConfig.available_sources_for(data_type)
          }
        }
      end

      # PATCH /api/v1/data_source_configs/:data_type
      def update
        unless DataSourceConfig::DATA_TYPES.include?(params[:data_type])
          return render json: { error: "Tipo de dado inválido" }, status: :not_found
        end

        config = current_tenant.data_source_configs.find_or_initialize_by(data_type: params[:data_type])
        config.source  = params[:source]
        config.enabled = ActiveModel::Type::Boolean.new.cast(params[:enabled]) if params[:enabled].present?

        if config.save
          render json: { data_type: config.data_type, source: config.source, enabled: config.enabled }
        else
          render json: { errors: config.errors.full_messages }, status: :unprocessable_entity
        end
      end
    end
  end
end
