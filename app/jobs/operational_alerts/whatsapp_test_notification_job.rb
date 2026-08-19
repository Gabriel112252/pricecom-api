# frozen_string_literal: true

module OperationalAlerts
  class WhatsappTestNotificationJob < ApplicationJob
    queue_as :integrations

    def perform(tenant_id)
      tenant = Tenant.find_by(id: tenant_id)
      return unless tenant

      recipients = ENV.fetch("WAHA_ALERT_TO", "")
        .split(/[\s,;]+/)
        .map(&:strip)
        .reject(&:blank?)
        .uniq

      if recipients.empty?
        Rails.logger.error(
          "[OperationalAlerts::WhatsappTestNotificationJob] tenant=#{tenant.id} failed: WAHA_ALERT_TO ausente"
        )
        return
      end

      client = Notifications::Whatsapp::WahaClient.new
      unless client.configured?
        Rails.logger.error(
          "[OperationalAlerts::WhatsappTestNotificationJob] tenant=#{tenant.id} failed: WAHA_URL/WAHA_API_KEY ausentes"
        )
        return
      end

      message = <<~TEXT.strip
        ✅ *#{tenant.name} — Teste de alerta WhatsApp*
        O canal de alertas operacionais está funcionando.
        Sessão: #{ENV.fetch("WAHA_SESSION", "default")}
        Enviado em: #{Time.current.in_time_zone("America/Sao_Paulo").strftime("%d/%m/%Y %H:%M:%S")}
        #{operation_url}
      TEXT

      delivered = recipients.count do |recipient|
        client.send_text(to: recipient, text: message)
        true
      rescue => e
        Rails.logger.error(
          "[OperationalAlerts::WhatsappTestNotificationJob] tenant=#{tenant.id} recipient_failed=#{e.class}: #{e.message}"
        )
        false
      end

      Rails.logger.info(
        "[OperationalAlerts::WhatsappTestNotificationJob] tenant=#{tenant.id} delivered=#{delivered}/#{recipients.length}"
      )
    end

    private

    def operation_url
      base = ENV.fetch("FRONTEND_URL", "").to_s.sub(%r{/+\z}, "")
      base.present? ? "Operação: #{base}/operacao" : ""
    end
  end
end
