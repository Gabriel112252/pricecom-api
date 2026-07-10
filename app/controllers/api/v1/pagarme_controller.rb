module Api
  module V1
    # Pagar.me (financial gateway) integration — automatic settlement
    # reconciliation, replacing the manual CSV import for tenants that
    # connect it. Credentials/status live on FinancialSource itself (it
    # already has provider/credentials/status/source_type columns) rather
    # than a separate credential record, since a financial source IS the
    # connection here.
    class PagarmeController < ApplicationController
      before_action :require_admin!

      # POST /api/v1/integrations/pagarme/connect
      def connect
        source = current_tenant.financial_sources.find_or_initialize_by(provider: "pagarme", name: "Pagar.me")
        source.source_type = "gateway"
        source.credentials  = credential_params
        source.status = "inactive"

        unless source.save
          return render json: { errors: source.errors.full_messages }, status: :unprocessable_entity
        end

        # payment_reconciliation defaults to pagarme the first time it's
        # connected — DataSourceConfig lets this be repointed later.
        DataSourceConfig.ensure_defaults_for_source!(current_tenant, "pagarme")

        begin
          Integrations::PagarmeAdapter.new(source.credentials).authenticate
          source.update!(status: "active")
        rescue Integrations::AuthenticationError, Integrations::ApiError, Integrations::RateLimitError => e
          source.update!(status: "error")
          return render json: { errors: [ e.message ] }, status: :unprocessable_entity
        end

        render json: source_json(source)
      end

      # POST /api/v1/integrations/pagarme/sync
      def sync
        source = current_tenant.financial_sources.find_by(provider: "pagarme")

        if source.nil? || source.status == "inactive"
          return render json: { error: "Pagar.me ainda não está conectado" }, status: :unprocessable_entity
        end

        days   = params[:days].presence || Financials::PagarmeSyncService::DEFAULT_DAYS
        result = Financials::PagarmeSyncService.call(source, days: days.to_i)

        render json: {
          success:       result.success?,
          created_count: result.created_count,
          updated_count: result.updated_count,
          skipped_count: result.skipped.size,
          skipped:       result.skipped.first(20),
          error_message: result.error_message
        }, status: result.success? ? :ok : :unprocessable_entity
      end

      private

      def credential_params
        params.require(:credentials).permit!.to_h
      end

      def source_json(source)
        {
          id:             source.id,
          provider:       source.provider,
          status:         source.status,
          last_synced_at: source.last_synced_at
        }
      end
    end
  end
end
