module Api
  module V1
    class TvTokensController < ApplicationController
      before_action :require_admin!

      def show
        render json: token_json
      end

      def create
        current_tenant.regenerate_tv_token!
        render json: token_json
      end

      def destroy
        current_tenant.revoke_tv_token!
        render json: token_json
      end

      private

      def token_json
        { tv_token: current_tenant.tv_token }
      end
    end
  end
end
