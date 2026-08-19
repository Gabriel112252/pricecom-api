# frozen_string_literal: true

module OperationalAlerts
  class WhatsappNotificationJob < ApplicationJob
    queue_as :integrations

    def perform
      unless configured?
        Rails.logger.warn(
          "[OperationalAlerts::WhatsappNotificationJob] WhatsApp desabilitado: " \
          "configure WAHA_URL, WAHA_API_KEY e WAHA_ALERT_TO"
        )
        return
      end

      Tenant.find_each do |tenant|
        result = OperationalAlerts::WhatsappNotifier.call(tenant)
        delivered = result.values.sum
        next if delivered.zero?

        Rails.logger.info(
          "[OperationalAlerts::WhatsappNotificationJob] tenant=#{tenant.id} delivered=#{delivered} " \
          "audit_conflicts=#{result[:audit_conflicts]} stock_alerts=#{result[:stock_alerts]} " \
          "integration_errors=#{result[:integration_errors]}"
        )
      rescue => e
        Rails.logger.error(
          "[OperationalAlerts::WhatsappNotificationJob] tenant=#{tenant.id} failed: #{e.class}: #{e.message}"
        )
      end
    end

    private

    def configured?
      ENV["WAHA_URL"].present? && ENV["WAHA_API_KEY"].present? && ENV["WAHA_ALERT_TO"].present?
    end
  end
end
