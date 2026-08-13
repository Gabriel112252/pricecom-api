# Só usado pelo caminho MCP — requests JWT normais resolvem current_user via
# ApplicationController#authenticate_request! e nunca tocam nisto. Setado
# pelo monkey-patch de auth do fast-mcp (ver config/initializers/fast_mcp.rb)
# a partir do mcp_api_key, mesmo padrão do ScrumFlow
# (~/projetos/scrumflow/back/app/models/current.rb).
class Current < ActiveSupport::CurrentAttributes
  attribute :user
end
