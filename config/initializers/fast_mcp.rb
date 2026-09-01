# frozen_string_literal: true

require "fast_mcp"

# fast-mcp 1.6.0 ships AuthenticatedRackTransport with two limitations for
# this app: auth_token procs are not evaluated by the stock comparison and
# query-param tokens are not accepted. The patch below keeps the same
# behavior already used by Pricecom, resolving the MCP user into Current.
module FastMcp
  module Transports
    class AuthenticatedRackTransport
      def handle_mcp_request(request, env)
        if auth_enabled? && !exempt_from_auth?(request.path)
          return unauthorized_response(request) unless valid_token?(extract_bearer_token(request))
        end

        super
      end

      private

      def extract_bearer_token(request)
        header_key = "HTTP_#{@auth_header_name.upcase.gsub('-', '_')}"
        from_header = request.env[header_key]&.sub(/\ABearer\s+/i, "")&.strip
        from_header.presence || request.params["token"].to_s.strip.presence
      end

      def valid_token?(token)
        return false if token.blank?

        if @auth_token.respond_to?(:call)
          user = @auth_token.call(token)
          return false unless user.present?

          Current.user = user
          true
        else
          token == @auth_token
        end
      end
    end
  end
end

# OAuth-like compatibility endpoints used by MCP clients such as Claude.ai.
# The existing Pricecom flow uses the user's mcp_api_key as the exchanged
# code/token and requires the consent screen in the authenticated frontend.
Rails.application.config.after_initialize do
  Rails.application.routes.prepend do
    get "/.well-known/oauth-authorization-server", to: ->(env) {
      base = ENV.fetch("APP_HOST", "https://pricecom-pricecom-api.dzxtro.easypanel.host")
      [200, { "Content-Type" => "application/json" }, [{
        issuer: base,
        authorization_endpoint: "#{base}/oauth/authorize",
        token_endpoint: "#{base}/oauth/token",
        registration_endpoint: "#{base}/register",
        response_types_supported: ["code"],
        grant_types_supported: ["authorization_code"],
        code_challenge_methods_supported: ["S256"]
      }.to_json]]
    }

    get "/.well-known/oauth-protected-resource", to: ->(env) {
      base = ENV.fetch("APP_HOST", "https://pricecom-pricecom-api.dzxtro.easypanel.host")
      [200, { "Content-Type" => "application/json" }, [{
        resource: "#{base}/mcp/sse",
        authorization_servers: [base]
      }.to_json]]
    }

    get "/.well-known/oauth-protected-resource/mcp/sse", to: ->(env) {
      base = ENV.fetch("APP_HOST", "https://pricecom-pricecom-api.dzxtro.easypanel.host")
      [200, { "Content-Type" => "application/json" }, [{
        resource: "#{base}/mcp/sse",
        authorization_servers: [base]
      }.to_json]]
    }

    post "/register", to: ->(env) {
      body = env["rack.input"].read
      redirect_uris = (JSON.parse(body)["redirect_uris"] rescue [])
      [200, { "Content-Type" => "application/json" }, [{
        client_id: "claude-ai",
        client_secret: "not-used",
        redirect_uris: redirect_uris
      }.to_json]]
    }

    get "/oauth/authorize", to: ->(env) {
      req = Rack::Request.new(env)
      redirect_uri = req.params["redirect_uri"]
      state = req.params["state"]
      frontend = ENV.fetch("FRONTEND_URL", "http://localhost:5173")
      location = "#{frontend}/configuracoes?mcp_callback=#{CGI.escape(redirect_uri.to_s)}&state=#{CGI.escape(state.to_s)}"
      [302, { "Location" => location, "Content-Type" => "text/html" }, []]
    }

    post "/oauth/token", to: ->(env) {
      req = Rack::Request.new(env)
      code = req.params["code"]
      user = User.find_by(mcp_api_key: code)
      if user
        [200, { "Content-Type" => "application/json" }, [{
          access_token: user.mcp_api_key,
          token_type: "Bearer",
          scope: "mcp"
        }.to_json]]
      else
        [401, { "Content-Type" => "application/json" }, [{ error: "invalid_grant" }.to_json]]
      end
    }
  end
end

FastMcp.mount_in_rails(
  Rails.application,
  name: "pricecom",
  version: "1.4.0",
  path_prefix: "/mcp",
  messages_route: "messages",
  sse_route: "sse",
  authenticate: true,
  auth_token: ->(token) { User.find_by(mcp_api_key: token) }
) do |server|
  Rails.application.config.after_initialize do
    # Consultas ao vivo ficam disponíveis para todo usuário autenticado.
    # Escritas de catálogo exigem admin, prévia/confirmar:true e auditoria.
    tools = [
      CatalogoPricecomTool,
      ResumoFinanceiroTool,
      ListarPedidosTool,
      ConsultarPedidoTool,
      BuscarProdutoTool,
      ConsultarProdutoDetalhadoTool,
      ConsultarProdutoOmnichannelTool,
      ConsultarEstoqueTool,
      StatusSincronizacaoCanalTool,
      ConsultarIntegracoesTool,
      ConsultarOperacaoTool,
      ConsultarCarrinhosTool,
      CriarEditarCredencialCanalTool,
      VincularProdutoCanalTool,
      AlterarProdutoCanalTool,
      ReplicarProdutoCanalTool,
      CriarCadastroProdutoTool,
      PublicarCadastroProdutoTool,
      DesfazerCadastroProdutoTool
    ]

    server.register_tools(*tools)
  end
end
