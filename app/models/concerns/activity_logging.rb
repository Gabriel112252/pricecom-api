# Compartilhado entre ApplicationController (requests JWT normais) e
# ApplicationTool (chamadas MCP) — ambos resolvem current_user/current_tenant
# do jeito deles (JWT decodificado vs. Current.user setado pelo monkey-patch
# de auth do fast-mcp), mas a regra de "como registrar uma ação" é uma só.
module ActivityLogging
  # Nunca deixa uma falha de log derrubar a ação principal — o efeito
  # colateral (criar usuário, mudar credencial, etc.) já aconteceu e não
  # deve ser desfeito só porque a auditoria não pôde ser escrita.
  #
  # target: qualquer ActiveRecord::Base — grava como target_type/target_id
  # simples (string+id), não um belongs_to polimórfico de verdade.
  def log_activity!(action:, target: nil, metadata: {}, tenant: nil, actor: nil)
    (tenant || current_tenant)&.user_activity_logs&.create!(
      user: actor || current_user,
      action: action,
      target_type: target&.class&.name,
      target_id: target&.id,
      metadata: metadata
    )
  rescue => e
    Rails.logger.error("[log_activity!] failed to record action=#{action}: #{e.message}")
  end
end
