module Api
  module V1
    # Public dashboard endpoint for TV Mode — no user session. Authorization
    # comes entirely from the unguessable tv_token in the URL, not from
    # skipping auth altogether (see Tenant#regenerate_tv_token!).
    class TvController < ApplicationController
      skip_before_action :authenticate_request!
      before_action :set_tenant_from_token!

      def summary
        render json: Dashboard::BuildSummary.call(tenant: @current_tenant, params: params)
      end

      private

      def set_tenant_from_token!
        token = params[:token].presence
        @current_tenant = token && Tenant.find_by(tv_token: token)

        render json: { error: "Link inválido ou revogado" }, status: :not_found unless @current_tenant
      end
    end
  end
end
