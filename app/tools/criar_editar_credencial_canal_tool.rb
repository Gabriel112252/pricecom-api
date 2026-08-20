# frozen_string_literal: true

class CriarEditarCredencialCanalTool < ApplicationTool
  description <<~DESC
    Cria ou substitui uma conexão de loja/canal (Yampi, Shopify, TikTok,
    Mercado Livre, Shopee, Lucrofrete). Suporta várias lojas do mesmo canal
    no tenant. AÇÃO SENSÍVEL — exige confirmar: true.
  DESC

  arguments do
    required(:canal).filled(:string).description("yampi, shopify, tiktok, mercadolivre, shopee ou lucrofrete")
    required(:credenciais).filled(:hash).description("Campos da credencial; nunca são devolvidos no resultado")
    optional(:nome_loja).filled(:string).description("Nome da conexão, ex: Hidrabene ou Anasol")
    optional(:credencial_id).filled(:integer).description("ID de uma conexão existente a editar")
    required(:confirmar).filled(:bool).description("Precisa ser true para gravar a configuração")
  end

  def call(canal:, credenciais:, confirmar:, nome_loja: nil, credencial_id: nil)
    admin_error = require_admin!
    return admin_error if admin_error
    return "Confirmação necessária: chame de novo com confirmar: true para prosseguir." unless confirmar
    return "Canal '#{canal}' inválido. Use um de: #{ChannelCredential::CHANNELS.join(', ')}." unless ChannelCredential::CHANNELS.include?(canal)

    tenant = current_tenant
    return "Usuário sem tenant associado." unless tenant

    credential = resolve_credential(tenant, canal, credencial_id: credencial_id, nome_loja: nome_loja)
    return credential if credential.is_a?(String)

    credential.credentials = credenciais
    credential.status = "pending"

    unless credential.save
      return "Não foi possível salvar: #{credential.errors.full_messages.join(', ')}"
    end

    log_activity!(
      action: "channel_credential.updated",
      target: credential,
      metadata: {
        channel: credential.channel,
        channel_credential_id: credential.id,
        connection_name: credential.display_name,
        source: "mcp"
      }
    )

    authenticate_if_possible(credential)

    {
      confirmacao: "Conexão #{credential.display_name} (#{credential.channel}) salva.",
      credencial_id: credential.id,
      canal: credential.channel,
      nome_loja: credential.display_name,
      status: credential.status,
      requer_oauth: %w[tiktok shopee].include?(credential.channel)
    }
  end

  private

  def resolve_credential(tenant, canal, credencial_id:, nome_loja:)
    scope = tenant.channel_credentials.where(channel: canal)

    if credencial_id.present?
      credential = scope.find_by(id: credencial_id)
      return credential if credential

      return "Credencial #{credencial_id} não encontrada para o canal #{canal}."
    end

    if nome_loja.present?
      return scope.find_or_initialize_by(name: nome_loja.to_s.strip)
    end

    records = scope.order(:id).limit(2).to_a
    return records.first if records.one?
    return tenant.channel_credentials.new(channel: canal, name: ChannelCredential.default_name_for(canal)) if records.empty?

    "Existem várias conexões para #{canal}. Informe credencial_id ou nome_loja para não sobrescrever a loja errada."
  end

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
    Rails.logger.warn("[CriarEditarCredencialCanalTool] auth failed channel_credential_id=#{credential.id}: #{e.message}")
  end
end
