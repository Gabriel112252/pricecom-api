# frozen_string_literal: true

class ConsultarOperacaoTool < ApplicationTool
  description "Consulta a fila operacional atual do Pricecom: integrações com problema, alertas de estoque, auditorias acionáveis e anomalias de volume de pedidos/SKU."

  ANOMALY_TYPES = %w[order_volume_drop sku_volume_drop].freeze
  STOCK_OPEN_STATUSES = %w[pending awaiting_confirmation insufficient_reserve failed].freeze
  RESULT_LIMIT = 50

  arguments do
    optional(:tipo).filled(:string).description("all, integracao, estoque, auditoria ou anomalia. Padrão: all")
    optional(:limite).filled(:integer).description("Máximo de itens por grupo. Padrão 20, máximo 50.")
  end

  def call(tipo: nil, limite: nil)
    tenant = current_tenant
    return "Usuário sem tenant associado." unless tenant

    kind = tipo.to_s.downcase.presence || "all"
    return "Tipo inválido. Use all, integracao, estoque, auditoria ou anomalia." unless %w[all integracao estoque auditoria anomalia].include?(kind)

    max = limite.to_i.positive? ? [ limite.to_i, RESULT_LIMIT ].min : 20
    result = { consultado_em: Time.current }

    result[:integracoes] = integration_issues(tenant, max) if %w[all integracao].include?(kind)
    result[:estoque] = stock_issues(tenant, max) if %w[all estoque].include?(kind)
    result[:auditoria] = audit_issues(tenant, max) if %w[all auditoria].include?(kind)
    result[:anomalias] = anomaly_issues(tenant, max) if %w[all anomalia].include?(kind)

    result[:resumo] = {
      integracoes: integration_issues(tenant, 1000).length,
      estoque: tenant.stock_alerts.where(status: STOCK_OPEN_STATUSES).count,
      auditoria: tenant.audit_conflicts.open.where.not(conflict_type: [ "missing_cost", *ANOMALY_TYPES ]).count,
      anomalias: tenant.audit_conflicts.open.where(conflict_type: ANOMALY_TYPES).count
    }

    result
  end

  private

  def integration_issues(tenant, limit)
    tenant.integrations.where(active: true).includes(:channel).filter_map do |integration|
      health = integration_health(tenant, integration)
      health unless health[:saude] == "healthy" || health[:saude] == "idle"
    end.first(limit)
  end

  def integration_health(tenant, integration)
    events = tenant.integration_events.where(integration_id: integration.id)
    logs = tenant.integration_sync_logs.where(integration_id: integration.id)

    last_success = logs.where(status: "success").maximum(:finished_at)
    last_error = logs.where(status: "error").maximum(:finished_at)
    last_event_error = events.where(status: "error").maximum(:updated_at)
    pending = events.where(status: "pending").count
    latest_failure = [ last_error, last_event_error ].compact.max

    status = if latest_failure.present? && (last_success.blank? || latest_failure > last_success)
      "error"
    elsif pending.positive?
      "pending"
    elsif last_success.present?
      "healthy"
    else
      "idle"
    end

    {
      id: integration.id,
      nome: integration.name,
      provider: integration.provider,
      canal: integration.channel&.name,
      status_conexao: integration.status,
      saude: status,
      eventos_pendentes: pending,
      ultima_sincronizacao: integration.last_synced_at,
      ultimo_sucesso: last_success,
      ultimo_erro: latest_failure,
      erros_ultimas_24h: logs.where(status: "error").where("created_at >= ?", 24.hours.ago).count
    }
  end

  def stock_issues(tenant, limit)
    tenant.stock_alerts
      .includes(:product)
      .where(status: STOCK_OPEN_STATUSES)
      .order(created_at: :desc)
      .limit(limit)
      .map do |alert|
        {
          id: alert.id,
          status: alert.status,
          sku: alert.product&.sku,
          produto: alert.product&.name,
          canal: alert.channel,
          quantidade_no_disparo: alert.qty_at_trigger,
          reposicao_sugerida: alert.suggested_replenishment_qty,
          erro: alert.error_message,
          criado_em: alert.created_at
        }
      end
  end

  def audit_issues(tenant, limit)
    tenant.audit_conflicts
      .open
      .includes(:order, :product)
      .where.not(conflict_type: [ "missing_cost", *ANOMALY_TYPES ])
      .order(created_at: :desc)
      .limit(limit)
      .map { |conflict| conflict_payload(conflict) }
  end

  def anomaly_issues(tenant, limit)
    tenant.audit_conflicts
      .open
      .includes(:order, :product)
      .where(conflict_type: ANOMALY_TYPES)
      .order(created_at: :desc)
      .limit(limit)
      .map do |conflict|
        conflict_payload(conflict).merge(
          esperado: conflict.expected_value,
          atual: conflict.actual_value,
          queda_pct: conflict.metadata.to_h["drop_pct"],
          janela_minutos: conflict.metadata.to_h["window_minutes"],
          canal: conflict.metadata.to_h["channel_name"],
          sku: conflict.metadata.to_h["sku"] || conflict.product&.sku,
          checado_em: conflict.metadata.to_h["last_checked_at"]
        )
      end
  end

  def conflict_payload(conflict)
    {
      id: conflict.id,
      tipo: conflict.conflict_type,
      severidade: conflict.severity,
      pedido: conflict.order&.order_number,
      sku: conflict.product&.sku,
      diferenca: conflict.difference,
      metadata: conflict.metadata,
      criado_em: conflict.created_at
    }
  end
end
