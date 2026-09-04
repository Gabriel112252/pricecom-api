# frozen_string_literal: true

module Api
  module V1
    class BlingObservabilityController < ApplicationController
      def dashboard
        render json: integrator_client.bling_dashboard(
          date_from: params[:date_from],
          date_to: params[:date_to]
        )
      rescue Integrations::YampiIdworksIntegratorClient::Error => error
        render json: { error: error.message }, status: :bad_gateway
      end

      def issues
        render json: integrator_client.bling_operational_issues(
          date_from: params[:date_from],
          date_to: params[:date_to],
          limit: params[:limit]
        )
      rescue Integrations::YampiIdworksIntegratorClient::Error => error
        render json: { error: error.message }, status: :bad_gateway
      end

      private

      def integrator_client
        @integrator_client ||= Integrations::YampiIdworksIntegratorClient.new
      end
    end
  end
end
