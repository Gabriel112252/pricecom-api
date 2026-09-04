module Api
  module V1
    class IntegrationHealthController < ApplicationController
      def index
        return render_bling_observability if params[:provider].to_s == "bling"

        integrations = current_tenant.integrations.active.includes(:channel)
        rows = integrations.map { |i| health_json(i) }

        render json: rows + bling_operational_health_rows
      end

      private

      def render_bling_observability
        client = Integrations::YampiIdworksIntegratorClient.new
        payload = if params[:view].to_s == "issues"
          client.bling_operational_issues(
            date_from: params[:date_from],
            date_to: params[:date_to],
            limit: params[:limit]
          )
        else
          client.bling_dashboard(
            date_from: params[:date_from],
            date_to: params[:date_to]
          )
        end

        render json: payload
      rescue Integrations::YampiIdworksIntegratorClient::Error => error
        render json: { error: error.message }, status: :bad_gateway
      end

      def bling_operational_health_rows
        payload = Integrations::YampiIdworksIntegratorClient.new.bling_operational_issues(limit: 100)
        Array(payload["issues"]).map { |issue| bling_issue_health_json(issue) }
      rescue Integrations::YampiIdworksIntegratorClient::Error => error
        Rails.logger.warn(
          {
            event: "pricecom.bling_observability.unavailable",
            error_class: error.class.name,
            error_message: error.message
          }.to_json
        )
        []
      end

      def bling_issue_health_json(issue)
        severity = issue["severity"].to_s
        timestamp = issue["last_seen_at"] || issue["first_seen_at"]
        critical = %w[critical high].include?(severity)
        order = issue["yampi_number"].presence || issue["yampi_id"].presence
        category = bling_category_label(issue["category"])
        short_message = issue["message"].to_s.squish.truncate(90)

        {
          id: "bling-#{issue['id']}",
          provider: "bling",
          name: [ "Bling", order ? "Pedido #{order}" : nil, category, short_message ].compact.join(" · "),
          status: critical ? "error" : "syncing",
          channel_id: nil,
          channel_name: "Yampi → Bling",
          last_synced_at: nil,
          last_event_at: timestamp,
          last_event_error_at: critical ? timestamp : nil,
          last_success_at: nil,
          last_error_at: critical ? timestamp : nil,
          events_pending_count: critical ? 0 : 1,
          events_error_count: critical ? 1 : 0,
          logs_success_last_24h: 0,
          logs_error_last_24h: critical ? 1 : 0,
          health_status: critical ? "error" : "pending",
          operational_issue: issue
        }
      end

      def bling_category_label(category)
        {
          "auth" => "OAuth",
          "product" => "SKU/produto",
          "validation" => "Validação",
          "order_create" => "Criação do pedido",
          "invoice" => "NF-e",
          "tracking" => "Rastreio",
          "status" => "Status"
        }.fetch(category.to_s, category.to_s.presence || "Integração")
      end

      def health_json(integration)
        since_24h = 24.hours.ago

        events_scope = current_tenant.integration_events
                         .where(integration_id: integration.id)
        logs_scope   = current_tenant.integration_sync_logs
                         .where(integration_id: integration.id)

        last_event_at         = events_scope.maximum(:created_at)
        last_event_error_at   = events_scope.where(status: "error").maximum(:updated_at)
        last_success_at       = logs_scope.where(status: "success").maximum(:finished_at)
        last_error_at         = logs_scope.where(status: "error").maximum(:finished_at)
        events_pending_count  = events_scope.where(status: "pending").count
        events_error_count    = events_scope.where(status: "error").count
        logs_success_last_24h = logs_scope.where(status: "success")
                                          .where("created_at >= ?", since_24h).count
        logs_error_last_24h   = logs_scope.where(status: "error")
                                          .where("created_at >= ?", since_24h).count

        {
          id:                    integration.id,
          provider:              integration.provider,
          name:                  integration.name,
          status:                integration.status,
          channel_id:            integration.channel_id,
          channel_name:          integration.channel&.name,
          last_synced_at:        integration.last_synced_at,
          last_event_at:         last_event_at,
          last_event_error_at:   last_event_error_at,
          last_success_at:       last_success_at,
          last_error_at:         last_error_at,
          events_pending_count:  events_pending_count,
          events_error_count:    events_error_count,
          logs_success_last_24h: logs_success_last_24h,
          logs_error_last_24h:   logs_error_last_24h,
          health_status:         resolve_health_status(
            events_pending_count: events_pending_count,
            last_success_at:      last_success_at,
            last_error_at:        last_error_at,
            last_event_error_at:  last_event_error_at
          )
        }
      end

      # Um erro histórico não mantém a integração vermelha para sempre.
      # O estado é "error" somente quando a falha mais recente aconteceu
      # depois do último sync bem-sucedido (ou quando nunca houve sucesso).
      def resolve_health_status(events_pending_count:, last_success_at:, last_error_at:, last_event_error_at:)
        latest_failure_at = [ last_error_at, last_event_error_at ].compact.max

        if latest_failure_at.present? && (last_success_at.blank? || latest_failure_at > last_success_at)
          return "error"
        end

        return "pending" if events_pending_count > 0
        return "healthy" if last_success_at.present?
        "idle"
      end
    end
  end
end
