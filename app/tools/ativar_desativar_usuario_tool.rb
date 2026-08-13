# frozen_string_literal: true

class AtivarDesativarUsuarioTool < ApplicationTool
  description "Ativa ou desativa um usuário do tenant. Um admin não pode desativar a própria conta."

  arguments do
    required(:usuario_id).filled(:integer).description("ID do usuário (use listar_usuarios ou a tela de Usuários para descobrir)")
    required(:ativar).filled(:bool).description("true para ativar/reativar, false para desativar")
  end

  # Reaproveita User#deactivate!/#reactivate! — mesmos métodos que
  # Api::V1::UsersController#destroy/#update usam, então a trava de
  # autodesativação (User#deactivate!) vive num só lugar.
  def call(usuario_id:, ativar:)
    admin_error = require_admin!
    return admin_error if admin_error

    tenant = current_tenant
    return "Usuário sem tenant associado." unless tenant

    target = tenant.users.find_by(id: usuario_id)
    return "Usuário #{usuario_id} não encontrado neste tenant." unless target

    if ativar
      target.reactivate!
      log_activity!(action: "user.updated", target: target, metadata: { active: true, source: "mcp" })
      { confirmacao: "#{target.name} reativado.", usuario_id: target.id, ativo: true }
    else
      unless target.deactivate!(actor: current_user)
        return "Você não pode desativar sua própria conta."
      end

      log_activity!(action: "user.deactivated", target: target, metadata: { source: "mcp" })
      { confirmacao: "#{target.name} desativado.", usuario_id: target.id, ativo: false }
    end
  end
end
