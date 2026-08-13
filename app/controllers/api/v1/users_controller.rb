module Api
  module V1
    class UsersController < ApplicationController
      skip_before_action :authenticate_request!, only: [ :accept_invitation ]
      before_action :require_admin!, only: [ :index, :create, :update, :destroy ]
      before_action :set_user, only: [ :update, :destroy ]

      # GET /api/v1/users — só do tenant atual, nunca User.all (isolamento
      # multi-tenant é responsabilidade de toda query aqui, não só desta).
      def index
        render json: current_tenant.users.order(:name).map { |u| user_json(u) }
      end

      # POST /api/v1/users
      # invite=true (ou invite=1): cria sem senha, gera invitation_token e
      # dispara UserMailer#invitation_email. Sem invite: cadastro direto,
      # senha obrigatória (ver User#password_required?).
      def create
        user = current_tenant.users.build(name: params[:name], email: params[:email])

        unless assign_role!(user, params[:role])
          return render json: { errors: [ "Role inválida" ] }, status: :unprocessable_entity
        end

        invite = ActiveModel::Type::Boolean.new.cast(params[:invite])
        user.start_invitation! if invite
        user.password = params[:password] unless invite

        if user.save
          log_activity!(action: "user.created", target: user, metadata: { invited: invite, role: user.role })

          if invite
            deliver_invitation(user)
          end

          render json: user_json(user), status: :created
        else
          render json: { errors: user.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH /api/v1/users/:id — nome, role e/ou active (reativação inclusa
      # — ver #destroy pro caminho de desativação rápida). Autodesativação
      # por aqui é bloqueada do mesmo jeito que em #destroy.
      def update
        if params.key?(:role) && !valid_role?(params[:role])
          return render json: { errors: [ "Role inválida" ] }, status: :unprocessable_entity
        end

        if deactivating_self?(params[:active])
          return render json: { error: "Você não pode desativar sua própria conta." }, status: :forbidden
        end

        previous_role = @user.role
        attrs = params.permit(:name, :role, :active).to_h
        # boolean vindo de query/form string ("false") — sem isso,
        # update(active: "false") é truthy em Ruby e o toggle nunca desliga.
        attrs["active"] = ActiveModel::Type::Boolean.new.cast(attrs["active"]) if attrs.key?("active")

        if @user.update(attrs)
          log_role_change(@user, previous_role) if attrs["role"].present? && attrs["role"] != previous_role
          log_activity!(action: "user.updated", target: @user, metadata: { changes: attrs.keys })
          render json: user_json(@user)
        else
          render json: { errors: @user.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/users/:id — não deleta, só active=false (histórico
      # preservado — audit_conflicts.resolved_by_id, affiliate_campaigns.
      # created_by_id, etc. continuam íntegros).
      def destroy
        unless @user.deactivate!(actor: current_user)
          return render json: { error: "Você não pode desativar sua própria conta." }, status: :forbidden
        end

        log_activity!(action: "user.deactivated", target: @user)
        render json: user_json(@user)
      end

      # POST /api/v1/users/accept_invitation — público, sem tenant/usuário
      # autenticado ainda (é assim que o usuário convidado ganha acesso pela
      # primeira vez). Token é global (índice único cross-tenant), não
      # precisa de escopo de tenant pra buscar.
      def accept_invitation
        user = User.find_by(invitation_token: params[:token])

        if user.nil?
          return render json: { error: "Convite inválido." }, status: :unprocessable_entity
        end

        if user.invitation_accepted_at.present?
          return render json: { error: "Este convite já foi utilizado." }, status: :unprocessable_entity
        end

        if user.invitation_expired?
          return render json: { error: "Este convite expirou. Peça para um administrador enviar um novo." }, status: :unprocessable_entity
        end

        if user.accept_invitation!(params[:password])
          log_activity!(action: "user.updated", target: user, metadata: { invitation_accepted: true }, tenant: user.tenant, actor: user)
          render json: { message: "Convite aceito. Você já pode entrar." }
        else
          render json: { errors: user.errors.full_messages }, status: :unprocessable_entity
        end
      end

      private

      def set_user
        @user = current_tenant.users.find(params[:id])
      end

      # role vem por enum — atribuir direto um valor fora de
      # User.roles.keys estoura ArgumentError (500) em vez de um 422
      # limpo, então valida antes de tocar no model.
      def valid_role?(role)
        role.blank? || User.roles.key?(role.to_s)
      end

      def assign_role!(user, role)
        return true if role.blank?
        return false unless valid_role?(role)

        user.role = role
        true
      end

      def deactivating_self?(active_param)
        return false unless params.key?(:active)
        return false unless @user == current_user

        !ActiveModel::Type::Boolean.new.cast(active_param)
      end

      def log_role_change(user, previous_role)
        log_activity!(action: "user.role_changed", target: user, metadata: { from: previous_role, to: user.role })
      end

      def deliver_invitation(user)
        UserMailer.invitation_email(user, current_user).deliver_later
      rescue => e
        # SMTP não configurado (dev/test) não pode travar a criação do
        # usuário — o convite existe e pode ser reenviado depois que o SMTP
        # estiver de pé; só o e-mail em si falha.
        Rails.logger.warn("[UsersController] failed to enqueue invitation email for user_id=#{user.id}: #{e.message}")
      end

      # password_digest nunca sai daqui, nem invitation_token — o link de
      # convite é reenviado por e-mail, não reexibido pela API depois de
      # criado.
      def user_json(user)
        {
          id: user.id,
          name: user.name,
          email: user.email,
          role: user.role,
          active: user.active,
          invitation_pending: user.invitation_pending?,
          created_at: user.created_at
        }
      end
    end
  end
end
