module Api
  module V1
    class IntegrationEventsController < ApplicationController
      def index
        events = current_tenant.integration_events.recent

        events = events.where(provider: params[:provider])           if params[:provider].present?
        events = events.where(event_type: params[:event_type])       if params[:event_type].present?
        events = events.where(status: params[:status])               if params[:status].present?
        events = events.where(integration_id: params[:integration_id]) if params[:integration_id].present?

        events_paged = events.page(params[:page]).per(50)

        render json: {
          events: events_paged.map { |e| event_summary_json(e) },
          meta: {
            current_page:  events_paged.current_page,
            total_pages:   events_paged.total_pages,
            total_count:   events_paged.total_count
          }
        }
      end

      def show
        event = current_tenant.integration_events.find(params[:id])
        render json: event_full_json(event)
      end

      private

      def event_summary_json(event)
        {
          id:             event.id,
          provider:       event.provider,
          event_type:     event.event_type,
          external_id:    event.external_id,
          external_type:  event.external_type,
          status:         event.status,
          integration_id: event.integration_id,
          received_at:    event.received_at,
          processed_at:   event.processed_at,
          error_message:  event.error_message,
          created_at:     event.created_at
        }
      end

      def event_full_json(event)
        event_summary_json(event).merge(
          payload:  event.payload,
          headers:  Integrations::HeaderRedactor.call(event.headers),
          metadata: event.metadata
        )
      end
    end
  end
end
