# frozen_string_literal: true

module OperationalAlerts
  class YampiIdworksDailyReconciliationJob < ApplicationJob
    queue_as :integrations

    CONFLICT_TYPE = "yampi_order_not_integrated".freeze
    TIME_ZONE = "America/Sao_Paulo".freeze

    def perform(date = nil)
      client = Integrations::YampiIdworksIntegratorClient.new
      tenant_slug = ENV.fetch("YAMPI_IDWORKS_TENANT_SLUG", "").to_s.strip

      unless client.configured? && tenant_slug.present?
        Rails.logger.warn(
          "[OperationalAlerts::YampiIdworksDailyReconciliationJob] disabled: configure " \
          "YAMPI_IDWORKS_INTEGRATOR_URL, YAMPI_IDWORKS_INTEGRATOR_TOKEN and YAMPI_IDWORKS_TENANT_SLUG"
        )
        return
      end

      tenant = Tenant.find_by(slug: tenant_slug)
      unless tenant
        Rails.logger.error(
          "[OperationalAlerts::YampiIdworksDailyReconciliationJob] tenant not found slug=#{tenant_slug.inspect}"
        )
        return
      end

      target_date = parse_date(date)
      response = client.daily_operational_issues(date: target_date.iso8601)
      issues = Array(response["issues"])

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

        attrs = conflict_attributes(issue, upstream_key, target_date, response)

        if conflict
          conflict.update!(attrs.merge(status: "open", resolved_at: nil, resolved_by: nil))
        else
          conflict = tenant.audit_conflicts.create!(attrs.merge(conflict_type: CONFLICT_TYPE, status: "open"))
          conflicts_by_key[upstream_key] = conflict
        end
      end

      # Intentionally does not resolve conflicts absent from this D-1 snapshot:
      # the frequent live reconciliation owns resolution. The daily job is a
      # closed-day guarantee and only needs to make missing orders visible.
      Rails.logger.info(
        "[OperationalAlerts::YampiIdworksDailyReconciliationJob] tenant=#{tenant.id} " \
        "date=#{target_date.iso8601} total_paid=#{response['total_paid_orders']} " \
        "integrated=#{response['integrated_orders']} missing=#{response['missing_orders']} " \
        "issues=#{issues.length} truncated=#{response['truncated'] == true}"
      )
    rescue Integrations::YampiIdworksIntegratorClient::Error => error
      Rails.logger.error(
        "[OperationalAlerts::YampiIdworksDailyReconciliationJob] upstream failed: #{error.class}: #{error.message}"
      )
    rescue Date::Error, ArgumentError => error
      Rails.logger.error(
        "[OperationalAlerts::YampiIdworksDailyReconciliationJob] invalid date: #{error.message}"
      )
    end

    private

    def parse_date(value)
      return ActiveSupport::TimeZone[TIME_ZONE].today.yesterday if value.blank?

      Date.iso8601(value.to_s)
    end

    def conflict_attributes(issue, upstream_key, target_date, response)
      yampi_number = issue["yampi_number"].presence
      yampi_id = issue["yampi_id"].presence
      identity = yampi_number || yampi_id || "sem identificação"
      last_error = issue["last_error"].to_s.presence

      notes = "Conciliação diária #{target_date.iso8601}: pedido Yampi #{identity} foi pago no dia anterior e ainda não possui pedido/mapeamento na IDWorks."
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
          "upstream_source" => "yampi_idworks_integrator",
          "daily_reconciliation" => true,
          "daily_reconciliation_date" => target_date.iso8601,
          "daily_total_paid_orders" => response["total_paid_orders"],
          "daily_integrated_orders" => response["integrated_orders"],
          "daily_missing_orders" => response["missing_orders"]
        )
      }
    end
  end
end
