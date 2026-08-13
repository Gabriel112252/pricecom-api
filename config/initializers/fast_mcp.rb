# frozen_string_literal: true

require "fast_mcp"

# fast-mcp 1.6.0 (a versão mais recente publicada até este levantamento —
# conferido em rubygems.org, sem versão mais nova) ships
# AuthenticatedRackTransport com duas limitações, confirmadas lendo o
# código de verdade da gem instalada
# (lib/mcp/transports/authenticated_rack_transport.rb):
#
#   1. valid_token? faz `token == @auth_token` — comparação direta de
#      string, então um auth_token lambda/proc sempre avalia falso.
#
#   2. Extração do token só lê o header Authorization; query param
#      `?token=` não é suportado (necessário pro conector MCP do Claude.ai).
#
# Mesmo patch já em produção no ScrumFlow
# (~/projetos/scrumflow/back/config/initializers/fast_mcp.rb) — reabrimos a
# classe aqui em vez de mudar a gem.
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

# Rotas OAuth-like — não é OAuth de verdade (o "code" trocado em
# /oauth/token É o mcp_api_key, gerado na hora do consentimento, não um
# código descartável de curta duração). É só o suficiente pro handshake que
# o conector MCP do Claude.ai/Claude Desktop espera antes de aceitar
# conectar como "App". Mesmo shim do ScrumFlow, adaptado pro fluxo de
# consentimento em /configuracoes (ver AcceptMcpConnection.vue no
# frontend).
#
# Risco residual conhecido, herdado do mesmo shim do ScrumFlow:
# redirect_uri não é validado contra um allowlist. A barreira real de
# segurança é o usuário precisar estar logado no Pricecom E clicar
# "Autorizar" na tela de consentimento — mas um redirect_uri malicioso
# aceito sem checagem é uma superfície de phishing teórica caso alguém
# convença um usuário autenticado a abrir um link de authorize forjado.
# Não é diferente do que o ScrumFlow já roda em produção, mas vale revisão
# futura (allowlist de host) se isso virar uma preocupação real.
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

    # Claude.ai registra um "client" dinamicamente antes de iniciar o
    # authorize — não guardamos nada disso (não há multi-client de
    # verdade aqui), só respondemos no formato que o protocolo espera.
    post "/register", to: ->(env) {
      body = env["rack.input"].read
      redirect_uris = (JSON.parse(body)["redirect_uris"] rescue [])
      [200, { "Content-Type" => "application/json" }, [{
        client_id: "claude-ai",
        client_secret: "not-used",
        redirect_uris: redirect_uris
      }.to_json]]
    }

    # Redireciona pro SPA — quem termina o consentimento (gera o
    # mcp_api_key e redireciona de volta pro redirect_uri com ?code=) é o
    # frontend, não este endpoint. Exige o usuário já estar logado no
    # Pricecom; se não estiver, o próprio guard de rotas do SPA manda pro
    # /login preservando esses query params via ?redirect=.
    get "/oauth/authorize", to: ->(env) {
      req = Rack::Request.new(env)
      redirect_uri = req.params["redirect_uri"]
      state = req.params["state"]
      frontend = ENV.fetch("FRONTEND_URL", "http://localhost:5173")
      location = "#{frontend}/configuracoes?mcp_callback=#{CGI.escape(redirect_uri.to_s)}&state=#{CGI.escape(state.to_s)}"
      [302, { "Location" => location, "Content-Type" => "text/html" }, []]
    }

    # "code" é o mcp_api_key em si (a tela de consentimento gera um novo
    # na hora de redirecionar de volta pro client) — não um código
    # intermediário. Trocar por ele mesmo só confirma que é um mcp_api_key
    # válido antes do client MCP passar a usá-lo como Bearer token.
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
  version: "1.0.0",
  path_prefix: "/mcp",
  messages_route: "messages",
  sse_route: "sse",
  authenticate: true,
  auth_token: ->(token) { User.find_by(mcp_api_key: token) }
) do |server|
  Rails.application.config.after_initialize do
    tools = [
      ResumoFinanceiroTool,
      BuscarProdutoTool,
      ListarPedidosTool,
      StatusSincronizacaoCanalTool,
      CriarEditarCredencialCanalTool,
      DispararSyncCanalTool,
      AtivarDesativarUsuarioTool
    ]

    server.register_tools(*tools)
  end
end
