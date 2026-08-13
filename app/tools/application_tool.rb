# frozen_string_literal: true

class ApplicationTool < ActionTool::Base
  include ActivityLogging

  private

  # Setado por config/initializers/fast_mcp.rb (auth_token: ->(token) {...})
  # quando o request MCP autentica com sucesso — nunca nil dentro de #call,
  # já que o monkey-patch de auth barra a request antes de chegar aqui.
  def current_user
    Current.user
  end

  # Nunca outro tenant — current_tenant vem sempre de current_user.tenant,
  # o mesmo caminho que ApplicationController usa pra request JWT normais,
  # então uma tool nunca pode vazar dado de um tenant que não é o do dono
  # do mcp_api_key usado.
  def current_tenant
    current_user&.tenant
  end

  # Guard pra tools de escrita — usar assim:
  #   return error if (error = require_admin!)
  # nil quando ok; String (erro, nunca exception) quando bloqueado — mesmo
  # formato de retorno de erro do resto das tools.
  def require_admin!
    return nil if current_user&.admin?

    "Acesso restrito a administradores."
  end
end
