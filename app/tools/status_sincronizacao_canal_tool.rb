# frozen_string_literal: true

class StatusSincronizacaoCanalTool < ApplicationTool
  description "Status de conexão e sincronização de um canal: última sync, se o polling automático está ligado e os últimos eventos de sync."

  arguments do
    optional(:canal).filled(:string).description("Nome do canal (ex: yampi, tiktok, shopify). Vazio = todos os canais conectados.")
  end

  def call(canal: nil)
    tenant = current_tenant
    return "Usuário sem tenant associado." unless tenant

    credentials = tenant.channel_credentials
    credentials = credentials.where(channel: canal.downcase) if canal.present?

    return "Canal '#{canal}' não conectado." if canal.present? && credentials.empty?

    { canais: credentials.map { |c| credential_status(c) } }
  end

  private

  def credential_status(credential)
    {
      canal: credential.channel,
      status: credential.status,
      polling_automatico: credential.polling_enabled,
      ultima_sincronizacao: credential.last_synced_at,
      cursor_pedidos: credential.orders_sync_cursor_at,
      ultimos_eventos: recent_logs(credential)
    }
  end

  def recent_logs(credential)
    IntegrationSyncLog
      .where(tenant: current_tenant, action: [ "product_sync", "yampi_order_polling" ])
      .where("metadata->>'channel_credential_id' = ?", credential.id.to_s)
      .order(created_at: :desc)
      .limit(3)
      .map { |log| { status: log.status, acao: log.action, erro: log.error_message, quando: log.created_at } }
  end
end
