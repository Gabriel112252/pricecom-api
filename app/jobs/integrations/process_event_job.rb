module Integrations
  class ProcessEventJob < ApplicationJob
    queue_as :integrations

    def perform(event_id)
      event = IntegrationEvent.find_by(id: event_id)
      return unless event
      return unless event.status == "pending"

      started_at = Time.current
      event.update_columns(status: "processing")

      result = Integrations::EventProcessor.call(event)

      finished_at  = Time.current
      duration_ms  = ((finished_at - started_at) * 1000).round

      if result.success?
        event.update_columns(
          status:       "processed",
          processed_at: finished_at,
          error_message: nil
        )
        log_status = "success"
      elsif result.skipped?
        event.update_columns(
          status:        "skipped",
          processed_at:  finished_at,
          error_message: result.error_message
        )
        log_status = "skipped"
      else
        event.update_columns(
          status:        "error",
          processed_at:  finished_at,
          error_message: result.error_message
        )
        log_status = "error"
      end

      IntegrationSyncLog.create!(
        tenant:        event.tenant,
        integration:   event.integration,
        direction:     "inbound",
        action:        "process_event",
        status:        log_status,
        external_id:   event.external_id,
        external_type: event.external_type,
        started_at:    started_at,
        finished_at:   finished_at,
        duration_ms:   duration_ms,
        metadata: {
          event_id:   event.id,
          provider:   event.provider,
          event_type: event.event_type,
          processor_metadata: result.metadata
        }
      )
    rescue => e
      event&.update_columns(
        status:        "error",
        processed_at:  Time.current,
        error_message: e.message
      )
      raise
    end
  end
end
