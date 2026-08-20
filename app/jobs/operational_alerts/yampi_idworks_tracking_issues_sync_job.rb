# frozen_string_literal: true

require "set"

module OperationalAlerts
  class YampiIdworksTrackingIssuesSyncJob < ApplicationJob
    queue_as :integrations

    CONFLICT_TYPE = "yampi_tracking_not_synced".freeze

    def perform(response = nil)
      client = Integrations::YampiIdworksIntegratorClient.new
      tenant_slug = ENV.fetch("YAMPI_IDWORKS_TENANT_SLUG", "").to_s.strip

      unless client.configured? && tenant_slug.present?
        Rails.logger.warn(
          "[OperationalAlerts::YampiIdworksTrackingIssuesSyncJob] disabled: configure " \
          "YAMPI_IDWORKS_INTEGRATOR_URL, YAMPI_IDWORKS_INTEGRATOR_TOKEN and YAMPI_IDWORKS_TENANT_SLUG"
        )
        return
      end

      tenant = Tenant.find_by(slug: tenant_slug)
      unless tenant
        Rails.logger.error(
          "[OperationalAlerts::YampiIdworksTrackingIssuesSyncJob] tenant not found slug=#{tenant_slug.inspect}"
        )
        return
      end

      response ||= client.tracking_operational_issues
      issues = Array(response["issues"])
      current_keys = issues.filter_map { |issue| issue["key"].to_s.presence }.to_set

      conflicts_by_key = tenant.audit_conflicts
        .where(conflict_type: CONFLICT_TYPE)
        .order(updated_at: :desc)
        .to_a
        .index_by { |conflict| conflict.metadata.to_h["upstream_key"].to_s }

      issues.each do |issue|
        upstream_key = issue["key"].to_s.presence
        next unless upstream_key

        conflict = conflicts_by_key[upstream_key]
        next if conflict&.status == "ignored"

        attrs = conflict_attributes(issue, upstream_key, response)

        if conflict
          conflict.update!(attrs.merge(status: "open", resolved_at: nil, resolved_by: nil))
        else
          conflict = tenant.audit_conflicts.create!(attrs.merge(conflict_type: CONFLICT_TYPE, status: "open"))
          conflicts_by_key[upstream_key] = conflict
        end
      end

      resolve_absent_conflicts(conflicts_by_key, current_keys) unless response["truncated"] == true

      Rails.logger.info(
        "[OperationalAlerts::YampiIdworksTrackingIssuesSyncJob] tenant=#{tenant.id} " \
        "issues=#{issues.length} truncated=#{response['truncated'] == true}"
      )
    rescue Integrations::YampiIdworksIntegratorClient::Error => error
      Rails.logger.error(
        "[OperationalAlerts::YampiIdworksTrackingIssuesSyncJob] upstream failed: #{error.class}: #{error.message}"
      )
    end

    private

    def conflict_attributes(issue, upstream_key, response)
      identity = issue["yampi_number"].presence || issue["yampi_id"].presence || "sem identificação"
      issue_message = issue["issue_message"].to_s.presence || "Pedido em transporte sem rastreio confirmado."

      {
        severity: "critical",
        source: "auto",
        expected_value: 1,
        actual_value: 0,
        difference: 1,
        notes: "Pedido Yampi #{identity}: #{issue_message}",
        metadata: issue.merge(
          "upstream_key" => upstream_key,
          "upstream_source" => "yampi_idworks_integrator",
          "tracking_required_status_id" => response["required_yampi_status_id"],
          "tracking_required_status_name" => response["required_yampi_status_name"],
          "tracking_last_reconciliation" => response["last_reconciliation"]
        )
      }
    end

    def resolve_absent_conflicts(conflicts_by_key, current_keys)
      now = Time.current

      conflicts_by_key.each do |key, conflict|
        next if key.blank? || current_keys.include?(key)
        next unless conflict.status == "open"

        conflict.update!(status: "resolved", resolved_at: now, resolved_by: nil)
      end
    end
  end
end
