class ApplicationController < ActionController::API
  include ExceptionHandler

  before_action :authenticate_request!

  rescue_from ExceptionHandler::AuthenticationError, with: :unauthorized
  rescue_from ExceptionHandler::InvalidToken, with: :unauthorized
  rescue_from ExceptionHandler::MissingToken, with: :unauthorized
  rescue_from ActiveRecord::RecordNotFound, with: :not_found

  private

  def authenticate_request!
    header = request.headers["Authorization"]
    raise ExceptionHandler::MissingToken, "Token ausente" unless header

    token = header.split(" ").last
    decoded = JsonWebToken.decode(token)
    @current_user = User.find(decoded[:user_id])
    @current_tenant = @current_user.tenant
  rescue ActiveRecord::RecordNotFound
    raise ExceptionHandler::AuthenticationError, "Usuário não encontrado"
  end

  def current_user
    @current_user
  end

  def current_tenant
    @current_tenant
  end

  # Guard for write/config endpoints — use as a `before_action`:
  #   before_action :require_admin!, only: [:update]
  # Read endpoints (index/show) are left open to any authenticated user
  # unless a controller has a specific reason to restrict reading too.
  def require_admin!
    return if current_user.admin?

    render json: { error: "Acesso restrito a administradores" }, status: :forbidden
  end

  def unauthorized(e)
    render json: { error: e.message }, status: :unauthorized
  end

  def not_found(e)
    render json: { error: e.message }, status: :not_found
  end
end
