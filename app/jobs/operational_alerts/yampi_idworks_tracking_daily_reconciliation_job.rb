# frozen_string_literal: true

module OperationalAlerts
  class YampiIdworksTrackingDailyReconciliationJob < ApplicationJob
    queue_as :integrations

    def perform
      client = Integrations::YampiIdworksIntegratorClient.new
      response = client.tracking_operational_issues
      reconciliation = response["last_reconciliation"].to_h

      Rails.logger.info(
        "[OperationalAlerts::YampiIdworksTrackingDailyReconciliationJob] " \
        "candidates=#{reconciliation['candidates']} checked=#{reconciliation['checked']} " \
        "required_status=#{reconciliation['required_status']} ok=#{reconciliation['ok']} " \
        "corrected=#{reconciliation['corrected']} open_issues=#{reconciliation['open_issues']} " \
        "errors=#{reconciliation['errors']} issue_counts=#{reconciliation['issue_counts'].inspect}"
      )

      YampiIdworksTrackingIssuesSyncJob.perform_now(response)
    rescue Integrations::YampiIdworksIntegratorClient::Error => error
      Rails.logger.error(
        "[OperationalAlerts::YampiIdworksTrackingDailyReconciliationJob] upstream failed: #{error.class}: #{error.message}"
      )
    end
  end
end
