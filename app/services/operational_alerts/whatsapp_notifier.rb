# frozen_string_literal: true

require "digest"

module OperationalAlerts
  class WhatsappNotifier
    ANOMALY_TYPES = %w[order_volume_drop sku_volume_drop].freeze
    UNINTEGRATED_ORDER_TYPE = "yampi_order_not_integrated".freeze
    NOTIFIABLE_SEVERITIES = %w[high critical].freeze
    MAX_SKUS_IN_SUMMARY = 5
    MAX_ORDERS_IN_SUMMARY = 5
    UNINTEGRATED_SUMMARY_TTL = 1.hour.to_i
    RECENT_INTEGRATION_FAILURE_WINDOW = 24.hours
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

    # Anomalias de venda costumam acontecer em conjunto: uma queda global de
    # pedidos naturalmente derruba varios SKUs ao mesmo tempo. A Operacao
    # continua mostrando cada anomalia individual para diagnostico, mas o
    # WhatsApp recebe um unico resumo por conjunto ativo de anomalias, em vez
    # de uma mensagem por SKU/canal. Alertas medium continuam visiveis na UI,
    # mas nao geram push — o WhatsApp fica reservado para high/critical.
    #
    # Pedidos Yampi sem IDWorks seguem a mesma regra de agrupamento: cada
    # pedido continua acionavel individualmente na Operacao, mas o WhatsApp
    # recebe no maximo um resumo por hora enquanto o incidente continuar.
    def notify_audit_conflicts
      anomalies = tenant.audit_conflicts.open
        .where(conflict_type: ANOMALY_TYPES, severity: NOTIFIABLE_SEVERITIES)
        .includes(:product)
        .to_a

      unintegrated_orders = tenant.audit_conflicts.open
        .where(conflict_type: UNINTEGRATED_ORDER_TYPE, severity: NOTIFIABLE_SEVERITIES)
        .to_a

      delivered = notify_anomaly_summary(anomalies)
      delivered += notify_unintegrated_orders_summary(unintegrated_orders)

      other_conflicts = tenant.audit_conflicts.open
        .where(severity: NOTIFIABLE_SEVERITIES)
        .where.not(conflict_type: [ "missing_cost", UNINTEGRATED_ORDER_TYPE, *ANOMALY_TYPES ])
        .includes(:product)

      delivered + other_conflicts.sum do |conflict|
        deliver_event(
          event_key: "audit:#{conflict.id}",
          text: audit_message(conflict)
        )
      end
    end

    def notify_anomaly_summary(anomalies)
      return 0 if anomalies.empty?

      # O ID do conflito e estavel enquanto a mesma anomalia permanece aberta.
      # Assim, atualizacoes de leitura a cada 15 min nao reenviam a mesma
      # mensagem; se surgir ou sumir uma anomalia relevante, o conjunto muda
      # e um novo resumo pode ser enviado.
      fingerprint = Digest::SHA256.hexdigest(anomalies.map(&:id).sort.join(","))[0, 20]

      deliver_event(
        event_key: "anomaly-summary:#{fingerprint}",
        text: anomaly_summary_message(anomalies)
      )
    end

    def notify_unintegrated_orders_summary(conflicts)
      return 0 if conflicts.empty?

      # Chave propositalmente estavel: durante uma falha sistemica novos
      # pedidos podem cruzar a janela de 2h a cada poucos minutos. Usar o
      # conjunto de IDs como fingerprint reenviaria a cada crescimento da
      # lista. Com TTL de 1h recebemos um resumo periódico, não uma rajada.
      deliver_event(
        event_key: "unintegrated-orders-active",
        text: unintegrated_orders_summary_message(conflicts),
        dedup_ttl: UNINTEGRATED_SUMMARY_TTL
      )
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
        next 0 if latest_failure < RECENT_INTEGRATION_FAILURE_WINDOW.ago
        next 0 if last_success.present? && latest_failure <= last_success

        deliver_event(
          event_key: "integration:#{integration.id}:#{latest_failure.to_i}",
          text: integration_message(integration, latest_failure, last_success)
        )
      end
    end

    def deliver_event(event_key:, text:, dedup_ttl: DEDUP_TTL)
      recipients.sum do |recipient|
        deliver_once(event_key: event_key, recipient: recipient, text: text, dedup_ttl: dedup_ttl) ? 1 : 0
      end
    end

    def deliver_once(event_key:, recipient:, text:, dedup_ttl: DEDUP_TTL)
      key = redis_key(event_key, recipient)
      claimed = Sidekiq.redis do |redis|
        redis.call("SET", key, "sending", "NX", "EX", CLAIM_TTL)
      end
      return false unless claimed

      client.send_text(to: recipient, text: text)
      Sidekiq.redis { |redis| redis.call("SET", key, "sent", "EX", dedup_ttl) }
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

    def anomaly_summary_message(anomalies)
      order_anomalies = anomalies.select { |conflict| conflict.conflict_type == "order_volume_drop" }
      sku_anomalies = anomalies.select { |conflict| conflict.conflict_type == "sku_volume_drop" }

      global = order_anomalies.find { |conflict| metadata_for(conflict)[:scope_key] == "all" }
      channels = order_anomalies.reject { |conflict| conflict == global }
        .sort_by { |conflict| -metadata_for(conflict)[:drop_pct].to_f }
      top_skus = sku_anomalies
        .sort_by { |conflict| [ -severity_rank(conflict.severity), -conflict.expected_value.to_f ] }
        .first(MAX_SKUS_IN_SUMMARY)

      critical = anomalies.any? { |conflict| conflict.severity == "critical" }
      lines = []
      lines << "#{critical ? '🚨' : '⚠️'} *#{tenant.name} — Anomalia de vendas*"

      if global
        lines << "Pedidos: *#{number(global.actual_value)}* vs ~#{number(global.expected_value)} esperados (*-#{number(metadata_for(global)[:drop_pct])}%*)"
      end

      if channels.any?
        lines << ""
        lines << "*Por canal:*"
        channels.each do |conflict|
          metadata = metadata_for(conflict)
          lines << "• #{metadata[:channel_name].presence || 'Canal'}: #{number(conflict.actual_value)} vs ~#{number(conflict.expected_value)} (*-#{number(metadata[:drop_pct])}%*)"
        end
      end

      if sku_anomalies.any?
        lines << ""
        if global
          lines << "*#{sku_anomalies.length} SKU(s) também abaixo do padrão* — provável reflexo da queda geral:"
        else
          lines << "*SKUs abaixo do padrão:*"
        end

        top_skus.each do |conflict|
          metadata = metadata_for(conflict)
          sku = metadata[:sku].presence || conflict.product&.sku || "-"
          channel_names = sku_channel_names(metadata)
          channel_suffix = channel_names.any? ? " — #{channel_names.join(', ')}" : ""
          lines << "• #{sku}: #{number(conflict.actual_value)} vs ~#{number(conflict.expected_value)} un. (*-#{number(metadata[:drop_pct])}%*)#{channel_suffix}"
        end

        remaining = sku_anomalies.length - top_skus.length
        lines << "• +#{remaining} outro(s) na Operação" if remaining.positive?
      end

      lines << ""
      lines << operation_url if operation_url.present?
      lines.compact.join("\n")
    end

    def unintegrated_orders_summary_message(conflicts)
      ordered = conflicts.sort_by { |conflict| -metadata_for(conflict)[:hours_waiting].to_f }
      lines = []
      lines << "🚨 *#{tenant.name} — Pedidos não integrados na IDWorks*"
      lines << "*#{conflicts.length} pedido(s)* pagos há mais de 2h continuam sem pedido/mapeamento na IDWorks."
      lines << ""

      ordered.first(MAX_ORDERS_IN_SUMMARY).each do |conflict|
        metadata = metadata_for(conflict)
        identity = metadata[:yampi_number].presence || metadata[:yampi_id].presence || conflict.id
        hours = metadata[:hours_waiting].to_f
        error = metadata[:last_error].to_s.squish.presence
        line = "• #{identity} — #{hours.positive? ? format('%.1fh', hours) : '>2h'}"
        line += " — #{error.first(120)}" if error
        lines << line
      end

      remaining = conflicts.length - MAX_ORDERS_IN_SUMMARY
      lines << "• +#{remaining} outro(s) na Operação" if remaining.positive?
      lines << ""
      lines << "Abra a Operação para reprocessar individualmente."
      lines << operation_url if operation_url.present?
      lines.compact.join("\n")
    end

    def audit_message(conflict)
      <<~TEXT.strip
        🚨 *#{tenant.name} — Pendência operacional #{severity_label(conflict.severity)}*
        Tipo: #{conflict.conflict_type}
        Esperado: #{number(conflict.expected_value)}
        Atual: #{number(conflict.actual_value)}
        #{operation_url}
      TEXT
    end

    def stock_message(alert)
      <<~TEXT.strip
        📦 *#{tenant.name} — Alerta de estoque*
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
        🔴 *#{tenant.name} — Falha de integração*
        Integração: *#{integration.name}* (#{integration.provider})
        Falha mais recente: #{format_time(latest_failure)}
        Último sucesso: #{last_success ? format_time(last_success) : "nenhum registrado"}
        #{operation_url}
      TEXT
    end

    def sku_channel_names(metadata)
      breakdown = Array(metadata[:channel_breakdown]).map { |row| row.to_h.with_indifferent_access }
      affected = breakdown.select { |row| ActiveModel::Type::Boolean.new.cast(row[:affected]) }
      selected = affected.any? ? affected : breakdown

      selected
        .filter_map { |row| row[:channel_name].to_s.presence }
        .uniq
        .first(3)
    end

    def metadata_for(conflict)
      conflict.metadata.to_h.with_indifferent_access
    end

    def operation_url
      base = ENV.fetch("FRONTEND_URL", "").to_s.sub(%r{/+\z}, "")
      base.present? ? "Operação: #{base}/operacao" : ""
    end

    def severity_rank(severity)
      { "critical" => 4, "high" => 3, "medium" => 2, "low" => 1 }.fetch(severity.to_s, 0)
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
