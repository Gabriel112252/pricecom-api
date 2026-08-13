module Api
  module V1
    # Token MCP — diferente de TvTokensController (tenant-wide, admin only),
    # este é por usuário: qualquer usuário autenticado gerencia o próprio
    # (decisão já tomada no levantamento: token único por usuário, sem
    # separar leitura/escrita). Valor bruto só aparece na resposta de
    # #create — nunca em #show nem em nenhum outro serializer.
    class McpTokensController < ApplicationController
      def show
        render json: { configured: current_user.mcp_api_key.present? }
      end

      def create
        current_user.regenerate_mcp_api_key!
        render json: { mcp_api_key: current_user.mcp_api_key, mcp_url: mcp_url }
      end

      private

      def mcp_url
        "#{ENV.fetch('APP_HOST', request.base_url)}/mcp/sse"
      end
    end
  end
end
