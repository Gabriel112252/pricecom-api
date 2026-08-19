# frozen_string_literal: true

module OperationalAlerts
  class YampiIdworksIssuesSyncJob < ApplicationJob
    queue_as :integrations

    CONFLICT_TYPE = "yampi_order_not_integrated".freeze

    def perform
      client = Integrations::YampiIdworksIntegratorClient.new
      tenant_slug = ENV.fetch("YAMPI_IDWORKS_TENANT_SLUG", "").to_s.strip

      unless client.configured? && tenant_slug.present?
        Rails.logger.warn(
          "[OperationalAlerts::YampiIdworksIssuesSyncJob] disabled: configure " \
          "YAMPI_IDWORKS_INTEGRATOR_URL, YAMPI_IDWORKS_INTEGRATOR_TOKEN and YAMPI_IDWORKS_TENANT_SLUG"
        )
        return
      end

      tenant = Tenant.find_by(slug: tenant_slug)
      unless tenant
        Rails.logger.error(
          "[OperationalAlerts::YampiIdworksIssuesSyncJob] tenant not found slug=#{tenant_slug.inspect}"
        )
        return
      end

      response = client.operational_issues
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

        attrs = conflict_attributes(issue, upstream_key)

        if conflict
          conflict.update!(attrs.merge(status: "open", resolved_at: nil, resolved_by: nil))
        else
          conflict = tenant.audit_conflicts.create!(attrs.merge(conflict_type: CONFLICT_TYPE, status: "open"))
          conflicts_by_key[upstream_key] = conflict
        end
      end

      # Only absence from a complete upstream snapshot proves resolution.
      # When the integrator returns more than its safety cap it marks the
      # response as truncated; in that case we keep unseen conflicts open.
      resolve_absent_conflicts(conflicts_by_key, current_keys) unless response["truncated"] == true

      Rails.logger.info(
        "[OperationalAlerts::YampiIdworksIssuesSyncJob] tenant=#{tenant.id} " \
        "issues=#{issues.length} truncated=#{response['truncated'] == true}"
      )
    rescue Integrations::YampiIdworksIntegratorClient::Error => error
      # Fail closed: if the source cannot be consulted, never resolve local
      # operational issues based on an empty/failed response.
      Rails.logger.error(
        "[OperationalAlerts::YampiIdworksIssuesSyncJob] upstream failed: #{error.class}: #{error.message}"
      )
    end

    private

    def conflict_attributes(issue, upstream_key)
      yampi_number = issue["yampi_number"].presence
      yampi_id = issue["yampi_id"].presence
      identity = yampi_number || yampi_id || "sem identificação"
      hours = issue["hours_waiting"]
      last_error = issue["last_error"].to_s.presence

      notes = "Pedido Yampi #{identity} pago há #{format_hours(hours)} ainda não possui pedido/mapeamento na IDWorks."
      notes += " Último erro: #{last_error}" if last_error

      {
        severity: "critical",
        source: "auto",
        expected_value: 1,
        actual_value: 0,
        difference: 1,
        notes: notes,
        metadata: issue.merge(
          "upstream_key" => upstream_key,
          "upstream_source" => "yampi_idworks_integrator"
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

    def format_hours(value)
      hours = value.to_f
      return "mais de 2h" unless hours.positive?

      hours == hours.to_i ? "#{hours.to_i}h" : "#{format('%.1f', hours)}h"
    end
  end
end
