module Api
  module V1
    class AuthController < ApplicationController
      skip_before_action :authenticate_request!, only: [:login]

      def login
        user = User.find_by(email: params[:email])
        tenant = user&.tenant

        if user&.authenticate(params[:password]) && user.active?
          token = JsonWebToken.encode(user_id: user.id, tenant_id: tenant.id)
          render json: {
            token: token,
            user: {
              id: user.id,
              name: user.name,
              email: user.email,
              role: user.role,
              tenant: {
                id: tenant.id,
                name: tenant.name,
                slug: tenant.slug
              }
            }
          }
        else
          render json: { error: "E-mail ou senha inválidos" }, status: :unauthorized
        end
      end

      def me
        render json: {
          user: {
            id: current_user.id,
            name: current_user.name,
            email: current_user.email,
            role: current_user.role
          }
        }
      end
    end
  end
end
