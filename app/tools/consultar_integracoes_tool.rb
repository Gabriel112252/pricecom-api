# frozen_string_literal: true

class ConsultarIntegracoesTool < ApplicationTool
  description "Consulta integrações e canais conectados do tenant, fontes de dados, últimos eventos e logs. Nunca retorna tokens, chaves ou credenciais sensíveis."

  RESULT_LIMIT = 50

  arguments do
    optional(:provider).filled(:string).description("Filtra provider/canal, ex: idworks, yampi, tiktok, shopee")
    optional(:status).filled(:string).description("Filtra status da integração")
    optional(:limite_logs).filled(:integer).description("Quantidade de eventos/logs recentes. Padrão 10, máximo 50.")
  end

  def call(provider: nil, status: nil, limite_logs: nil)
    tenant = current_tenant
    return "Usuário sem tenant associado." unless tenant

    max = limite_logs.to_i.positive? ? [ limite_logs.to_i, RESULT_LIMIT ].min : 10

    integrations = tenant.integrations.includes(:channel)
    integrations = integrations.where("LOWER(provider) = ?", provider.downcase) if provider.present?
    integrations = integrations.where(status: status) if status.present?

    credentials = tenant.channel_credentials
    credentials = credentials.where("LOWER(channel) = ?", provider.downcase) if provider.present?

    integrations = integrations.to_a
    credentials = credentials.to_a

    {
      integracoes: integrations.sort_by { |integration| [ integration.provider.to_s, integration.name.to_s ] }.map { |integration| integration_payload(integration) },
      credenciais_de_canal: credentials.sort_by { |credential| credential.channel.to_s }.map { |credential| credential_payload(credential) },
      fontes_de_dados: tenant.data_source_configs.order(:data_type).map do |config|
        {
          tipo: config.data_type,
          fonte: config.source,
          habilitada: config.enabled,
          atualizado_em: config.updated_at
        }
      end,
      eventos_recentes: recent_events(tenant, integrations, credentials, provider, max),
      logs_recentes: recent_logs(tenant, integrations, credentials, provider, max)
    }
  end

  private

  def integration_payload(integration)
    {
      id: integration.id,
      nome: integration.name,
      provider: integration.provider,
      status: integration.status,
      ativo: integration.active,
      canal: integration.channel&.name,
      ultima_sincronizacao: integration.last_synced_at,
      atualizado_em: integration.updated_at
    }
  end

  def credential_payload(credential)
    {
      id: credential.id,
      canal: credential.channel,
      status: credential.status,
      role: credential.role,
      polling_habilitado: credential.polling_enabled,
      ultima_sincronizacao: credential.last_synced_at,
      cursor_pedidos: credential.orders_sync_cursor_at,
      cursor_carrinhos: credential.carts_sync_cursor_at,
      atualizado_em: credential.updated_at
    }
  end

  def recent_events(tenant, integrations, credentials, provider, limit)
    scope = tenant.integration_events
    integration_ids = integrations.map(&:id)

    if provider.present? && integration_ids.empty? && credentials.empty?
      return []
    elsif integration_ids.any?
      scope = scope.where(integration_id: integration_ids)
    elsif credentials.any?
      scope = scope.where(provider: credentials.map(&:channel))
    end

    scope.order(created_at: :desc).limit(limit).map do |event|
      {
        id: event.id,
        provider: event.provider,
        integracao_id: event.integration_id,
        tipo: event.event_type,
        external_id: event.external_id,
        external_type: event.external_type,
        status: event.status,
        erro: event.error_message,
        recebido_em: event.received_at,
        processado_em: event.processed_at,
        criado_em: event.created_at
      }
    end
  end

  def recent_logs(tenant, integrations, credentials, provider, limit)
    scope = tenant.integration_sync_logs
    integration_ids = integrations.map(&:id)
    credential_ids = credentials.map(&:id)

    if provider.present? && integration_ids.empty? && credential_ids.empty?
      return []
    end

    if integration_ids.any? || credential_ids.any?
      clauses = []
      binds = {}

      if integration_ids.any?
        clauses << "integration_id IN (:integration_ids)"
        binds[:integration_ids] = integration_ids
      end

      if credential_ids.any?
        clauses << "channel_credential_id IN (:credential_ids)"
        binds[:credential_ids] = credential_ids
      end

      scope = scope.where(clauses.join(" OR "), binds)
    end

    scope.order(created_at: :desc).limit(limit).map do |log|
      {
        id: log.id,
        integracao_id: log.integration_id,
        credencial_canal_id: log.channel_credential_id,
        direcao: log.direction,
        acao: log.action,
        status: log.status,
        external_id: log.external_id,
        external_type: log.external_type,
        erro: log.error_message,
        duracao_ms: log.duration_ms,
        inicio: log.started_at,
        fim: log.finished_at,
        criado_em: log.created_at
      }
    end
  end
end
