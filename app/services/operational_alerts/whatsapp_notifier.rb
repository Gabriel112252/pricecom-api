# frozen_string_literal: true

require "digest"

module OperationalAlerts
  class WhatsappNotifier
    ANOMALY_TYPES = %w[order_volume_drop sku_volume_drop].freeze
    NOTIFIABLE_SEVERITIES = %w[high critical].freeze
    DEDUP_TTL = 90.days.to_i
    CLAIM_TTL = 5.minutes.to_i

    def self.call(tenant)
      new(tenant).call
    end

    def initialize(tenant, client: Notifications::Whatsapp::WahaClient.new)
      @tenant = tenant
      @client = client
    end

    def call
      return empty_result unless configured?

      {
        audit_conflicts: notify_audit_conflicts,
        stock_alerts: notify_stock_alerts,
        integration_errors: notify_integration_errors
      }
    end

    private

    attr_reader :tenant, :client

    def configured?
      client.configured? && recipients.any?
    end

    def empty_result
      { audit_conflicts: 0, stock_alerts: 0, integration_errors: 0 }
    end

    def recipients
      @recipients ||= ENV.fetch("WAHA_ALERT_TO", "")
        .split(/[\s,;]+/)
        .map(&:strip)
        .reject(&:blank?)
        .uniq
    end

    def notify_audit_conflicts
      scope = tenant.audit_conflicts.open
        .where.not(conflict_type: "missing_cost")
        .where(
          "severity IN (:severities) OR conflict_type IN (:anomalies)",
          severities: NOTIFIABLE_SEVERITIES,
          anomalies: ANOMALY_TYPES
        )
        .includes(:product)

      scope.sum do |conflict|
        deliver_event(
          event_key: "audit:#{conflict.id}",
          text: audit_message(conflict)
        )
      end
    end

    def notify_stock_alerts
      tenant.stock_alerts.open.includes(:product).sum do |alert|
        deliver_event(
          event_key: "stock:#{alert.id}",
          text: stock_message(alert)
        )
      end
    end

    def notify_integration_errors
      integrations = tenant.integrations.active.to_a
      return 0 if integrations.empty?

      ids = integrations.map(&:id)
      logs = tenant.integration_sync_logs.where(integration_id: ids)
      events = tenant.integration_events.where(integration_id: ids)

      last_success_by_id = logs.where(status: "success").group(:integration_id).maximum(:finished_at)
      last_error_by_id = logs.where(status: "error").group(:integration_id).maximum(:finished_at)
      last_event_error_by_id = events.where(status: "error").group(:integration_id).maximum(:updated_at)

      integrations.sum do |integration|
        last_success = last_success_by_id[integration.id]
        latest_failure = [
          last_error_by_id[integration.id],
          last_event_error_by_id[integration.id]
        ].compact.max

        next 0 if latest_failure.blank?
        next 0 if last_success.present? && latest_failure <= last_success

        deliver_event(
          event_key: "integration:#{integration.id}:#{latest_failure.to_i}",
          text: integration_message(integration, latest_failure, last_success)
        )
      end
    end

    def deliver_event(event_key:, text:)
      recipients.sum do |recipient|
        deliver_once(event_key: event_key, recipient: recipient, text: text) ? 1 : 0
      end
    end

    def deliver_once(event_key:, recipient:, text:)
      key = redis_key(event_key, recipient)
      claimed = Sidekiq.redis do |redis|
        redis.call("SET", key, "sending", "NX", "EX", CLAIM_TTL)
      end
      return false unless claimed

      client.send_text(to: recipient, text: text)
      Sidekiq.redis { |redis| redis.call("SET", key, "sent", "EX", DEDUP_TTL) }
      true
    rescue => e
      Sidekiq.redis { |redis| redis.call("DEL", key) } if key
      Rails.logger.error(
        "[OperationalAlerts::WhatsappNotifier] tenant=#{tenant.id} event=#{event_key} " \
        "failed=#{e.class}: #{e.message}"
      )
      false
    end

    def redis_key(event_key, recipient)
      recipient_hash = Digest::SHA256.hexdigest(recipient.to_s)[0, 16]
      "pricecom:whatsapp:operational:#{tenant.id}:#{event_key}:#{recipient_hash}"
    end

    def audit_message(conflict)
      metadata = conflict.metadata.to_h.with_indifferent_access

      case conflict.conflict_type
      when "order_volume_drop"
        <<~TEXT.strip
          🚨 *Pricecom — Queda anormal de pedidos*
          #{tenant.name}
          Canal: #{metadata[:channel_name].presence || "Todos os canais"}
          Últimos #{metadata[:window_minutes] || 60} min: *#{number(conflict.actual_value)} pedidos*
          Esperado: ~#{number(conflict.expected_value)}
          Queda: *#{number(metadata[:drop_pct])}%*
          #{operation_url}
        TEXT
      when "sku_volume_drop"
        <<~TEXT.strip
          ⚠️ *Pricecom — Queda anormal de SKU*
          #{tenant.name}
          SKU: *#{metadata[:sku] || conflict.product&.sku || "-"}*
          Produto: #{metadata[:product_name].presence || conflict.product&.name || "-"}
          Últimos #{metadata[:window_minutes] || 60} min: *#{number(conflict.actual_value)} un.*
          Esperado: ~#{number(conflict.expected_value)} un.
          Queda: *#{number(metadata[:drop_pct])}%*
          #{operation_url}
        TEXT
      else
        <<~TEXT.strip
          🚨 *Pricecom — Pendência operacional #{severity_label(conflict.severity)}*
          #{tenant.name}
          Tipo: #{conflict.conflict_type}
          Esperado: #{number(conflict.expected_value)}
          Atual: #{number(conflict.actual_value)}
          #{operation_url}
        TEXT
      end
    end

    def stock_message(alert)
      <<~TEXT.strip
        📦 *Pricecom — Alerta de estoque*
        #{tenant.name}
        SKU: *#{alert.product&.sku || "-"}*
        Produto: #{alert.product&.name || "-"}
        Reserva disponível: *#{number(alert.qty_at_trigger)} un.*
        Reposição sugerida: #{number(alert.suggested_replenishment_qty)} un.
        Status: #{alert.status}
        #{operation_url}
      TEXT
    end

    def integration_message(integration, latest_failure, last_success)
      <<~TEXT.strip
        🔴 *Pricecom — Falha de integração*
        #{tenant.name}
        Integração: *#{integration.name}* (#{integration.provider})
        Falha mais recente: #{format_time(latest_failure)}
        Último sucesso: #{last_success ? format_time(last_success) : "nenhum registrado"}
        #{operation_url}
      TEXT
    end

    def operation_url
      base = ENV.fetch("FRONTEND_URL", "").to_s.sub(%r{/+\z}, "")
      base.present? ? "Operação: #{base}/operacao" : ""
    end

    def severity_label(severity)
      { "critical" => "CRÍTICA", "high" => "ALTA", "medium" => "MÉDIA", "low" => "BAIXA" }.fetch(severity, severity.to_s.upcase)
    end

    def format_time(value)
      value.in_time_zone("America/Sao_Paulo").strftime("%d/%m/%Y %H:%M")
    end

    def number(value)
      number = value.to_f
      number == number.to_i ? number.to_i.to_s : format("%.1f", number)
    end
  end
end
