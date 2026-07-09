module Api
  module V1
    class IntegrationHealthController < ApplicationController
      def index
        integrations = current_tenant.integrations.active.includes(:channel)

        render json: integrations.map { |i| health_json(i) }
      end

      private

      def health_json(integration)
        since_24h = 24.hours.ago

        events_scope = current_tenant.integration_events
                         .where(integration_id: integration.id)
        logs_scope   = current_tenant.integration_sync_logs
                         .where(integration_id: integration.id)

        last_event_at         = events_scope.maximum(:created_at)
        last_success_at       = logs_scope.where(status: "success").maximum(:finished_at)
        last_error_at         = logs_scope.where(status: "error").maximum(:finished_at)
        events_pending_count  = events_scope.where(status: "pending").count
        events_error_count    = events_scope.where(status: "error").count
        logs_success_last_24h = logs_scope.where(status: "success")
                                          .where("created_at >= ?", since_24h).count
        logs_error_last_24h   = logs_scope.where(status: "error")
                                          .where("created_at >= ?", since_24h).count

        {
          id:                   integration.id,
          provider:             integration.provider,
          name:                 integration.name,
          status:               integration.status,
          channel_id:           integration.channel_id,
          channel_name:         integration.channel&.name,
          last_synced_at:       integration.last_synced_at,
          last_event_at:        last_event_at,
          last_success_at:      last_success_at,
          last_error_at:        last_error_at,
          events_pending_count: events_pending_count,
          events_error_count:   events_error_count,
          logs_success_last_24h: logs_success_last_24h,
          logs_error_last_24h:   logs_error_last_24h,
          health_status:        resolve_health_status(
            logs_error_last_24h:  logs_error_last_24h,
            events_error_count:   events_error_count,
            events_pending_count: events_pending_count,
            last_success_at:      last_success_at
          )
        }
      end

      def resolve_health_status(logs_error_last_24h:, events_error_count:, events_pending_count:, last_success_at:)
        return "error"   if logs_error_last_24h > 0 || events_error_count > 0
        return "pending" if events_pending_count > 0
        return "healthy" if last_success_at.present?
        "idle"
      end
    end
  end
end
