module Api
  module V1
    class AuthController < ApplicationController
      skip_before_action :authenticate_request!, only: [:login]

      def login
        user = User.find_by(email: params[:email])
        tenant = user&.tenant

        if user&.authenticate(params[:password]) && user.active?
          log_activity!(action: "login.success", target: user, tenant: tenant, actor: user)
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
          # tenant pode ser nil (e-mail não corresponde a nenhum usuário) —
          # log_activity! não grava nada nesse caso (UserActivityLog exige
          # tenant_id): uma tentativa com e-mail desconhecido não pertence
          # a tenant nenhum, então não há onde registrá-la numa tabela
          # de auditoria escopada por tenant. Tentativa de senha errada
          # pra um e-mail que existe é logada normalmente.
          log_activity!(
            action: "login.failed",
            target: user,
            tenant: tenant,
            actor: user,
            metadata: { email: params[:email], reason: user.nil? ? "email_not_found" : (user.active? ? "wrong_password" : "inactive") }
          )
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
