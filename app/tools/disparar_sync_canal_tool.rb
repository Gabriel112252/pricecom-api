# frozen_string_literal: true

class DispararSyncCanalTool < ApplicationTool
  description "Força a sincronização de pedidos de um canal agora, fora do agendamento automático (mesmo job que roda no cron)."

  JOBS = {
    "yampi"  => Integrations::Yampi::OrdersPollingJob,
    "shopee" => Integrations::Shopee::OrdersPollingJob,
    "tiktok" => Integrations::Tiktok::OrdersPollingJob
  }.freeze

  arguments do
    required(:canal).filled(:string).description("yampi, shopee ou tiktok — únicos canais com polling de pedidos manual")
  end

  # Sem confirmar: true — ação idempotente e seguro (só antecipa um job que
  # rodaria de qualquer forma pelo cron), decisão já tomada no levantamento.
  def call(canal:)
    admin_error = require_admin!
    return admin_error if admin_error

    job_class = JOBS[canal.to_s.downcase]
    return "Canal '#{canal}' não suporta sincronização manual. Use um de: #{JOBS.keys.join(', ')}." unless job_class

    tenant = current_tenant
    return "Usuário sem tenant associado." unless tenant

    credential = tenant.channel_credentials.find_by(channel: canal.downcase)
    return "Canal '#{canal}' ainda não está conectado." if credential.nil? || credential.status == "pending"

    if polling_running?(credential)
      return "Sincronização do canal #{canal} já está em execução — aguarde terminar antes de disparar de novo."
    end

    job_class.perform_later(credential.id, trigger: "mcp")

    log_activity!(
      action: "channel_sync.triggered",
      target: credential,
      metadata: { channel: credential.channel, source: "mcp" }
    )

    { confirmacao: "Sincronização do canal #{credential.channel} disparada.", canal: credential.channel }
  end

  private

  # Mesmo fallback de ChannelCredentialsController#yampi_order_polling_running? —
  # uma falha ao checar o lock (Redis fora do ar, etc.) não pode virar uma
  # exception não tratada pro caller MCP; trata como "não está rodando" e
  # deixa a tentativa de disparo prosseguir.
  def polling_running?(credential)
    Integrations::OrdersPollingLock.new(credential).locked?
  rescue => e
    Rails.logger.warn("[DispararSyncCanalTool] lock check failed for channel_credential_id=#{credential.id}: #{e.message}")
    false
  end
end
