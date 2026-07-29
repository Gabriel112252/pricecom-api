module Api
  module V1
    # Mirrors TvTokensController — same show/create/destroy shape for a
    # different unguessable per-tenant public token (see
    # Tenant#regenerate_testimonials_public_token!).
    class TestimonialsPublicTokensController < ApplicationController
      before_action :require_admin!

      def show
        render json: token_json
      end

      def create
        current_tenant.regenerate_testimonials_public_token!
        render json: token_json
      end

      def destroy
        current_tenant.revoke_testimonials_public_token!
        render json: token_json
      end

      private

      def token_json
        { testimonials_public_token: current_tenant.testimonials_public_token }
      end
    end
  end
end
