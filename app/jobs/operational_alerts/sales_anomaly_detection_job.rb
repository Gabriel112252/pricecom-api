module OperationalAlerts
  class SalesAnomalyDetectionJob < ApplicationJob
    queue_as :integrations

    def perform
      Tenant.find_each do |tenant|
        result = OperationalAlerts::SalesAnomalyDetector.call(tenant)
        next if result.values.sum.zero?

        Rails.logger.info(
          "[OperationalAlerts::SalesAnomalyDetectionJob] tenant=#{tenant.id} " \
          "order_alerts=#{result[:order_alerts]} sku_alerts=#{result[:sku_alerts]}"
        )
      rescue => e
        Rails.logger.error(
          "[OperationalAlerts::SalesAnomalyDetectionJob] tenant=#{tenant.id} failed: #{e.class}: #{e.message}"
        )
      end
    end
  end
end
