# frozen_string_literal: true

class CriarEditarCredencialCanalTool < ApplicationTool
  description <<~DESC
    Cria ou substitui a credencial de um canal de vendas (Yampi, Shopify, TikTok,
    Mercado Livre, Shopee, Lucrofrete). AÇÃO SENSÍVEL — reconfigura a integração
    inteira do canal. Exige confirmar: true, sem o qual nada é executado.
  DESC

  # Mesmo shape de campos exigidos por canal já usado no formulário do
  # frontend e em ChannelCredential::REQUIRED_FIELDS — não reexplicado aqui
  # porque a tool aceita um Hash livre em `credenciais` e deixa a validação
  # de presença pro model (mesmo caminho que a REST API usa).
  arguments do
    required(:canal).filled(:string).description("yampi, shopify, tiktok, mercadolivre, shopee ou lucrofrete")
    required(:credenciais).filled(:hash).description("Campos da credencial (ex: {\"token\": \"...\", \"secret_key\": \"...\"})")
    required(:confirmar).filled(:bool).description("Precisa ser true — confirma a intenção de sobrescrever a credencial do canal")
  end

  def call(canal:, credenciais:, confirmar:)
    admin_error = require_admin!
    return admin_error if admin_error
    return "Confirmação necessária: chame de novo com confirmar: true para prosseguir." unless confirmar
    return "Canal '#{canal}' inválido. Use um de: #{ChannelCredential::CHANNELS.join(', ')}." unless ChannelCredential::CHANNELS.include?(canal)

    tenant = current_tenant
    return "Usuário sem tenant associado." unless tenant

    credential = tenant.channel_credentials.find_or_initialize_by(channel: canal)
    credential.credentials = credenciais
    credential.status = "pending"

    unless credential.save
      return "Não foi possível salvar: #{credential.errors.full_messages.join(', ')}"
    end

    # Só o fato de ter mudado, nunca os valores — mesmo cuidado do
    # ChannelCredentialsController#connect. source: "mcp" reaproveita a
    # action já existente (channel_credential.updated) em vez de criar uma
    # nova, decisão já tomada no levantamento anterior.
    log_activity!(
      action: "channel_credential.updated",
      target: credential,
      metadata: { channel: credential.channel, source: "mcp" }
    )

    authenticate_if_possible(credential)

    {
      confirmacao: "Credencial do canal #{credential.channel} salva.",
      canal: credential.channel,
      status: credential.status
    }
  end

  private

  # Mesma orquestração de ChannelCredentialsController#connect (Channel.
  # ensure_for!, autenticação imediata pros canais que não dependem de
  # OAuth) — duplicada aqui em vez de extraída pra um service porque o
  # controller já é testado e não queria arriscar mexer nele por essa
  # tool; se isso incomodar, uma extração futura pra
  # Integrations::ConnectChannelCredential resolve os dois de uma vez.
  def authenticate_if_possible(credential)
    if credential.channel == "lucrofrete"
      Integrations::LucrofreteClient.new(credential).authenticate!
      credential.update!(status: "active")
      return
    end

    Channel.ensure_for!(current_tenant, credential.channel)
    return if %w[tiktok shopee].include?(credential.channel)

    adapter_class = Integrations::ProductSyncService::ADAPTERS.fetch(credential.channel)
    adapter_class.new(credential.credentials).authenticate
    credential.update!(status: "active")
  rescue Integrations::AuthenticationError, Integrations::ApiError, Integrations::RateLimitError => e
    credential.update!(status: "error")
    # Não retorna erro pro caller — a credencial já foi salva (log já
    # gravado); status: "error" no retorno acima já comunica que a
    # autenticação falhou, mesmo comportamento de UX do endpoint REST.
    Rails.logger.warn("[CriarEditarCredencialCanalTool] auth failed channel=#{credential.channel}: #{e.message}")
  end
end
