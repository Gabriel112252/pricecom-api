module Integrations
  class EventRecorder
    Result = Struct.new(:ok, :event, :error_message) do
      def success? = ok
    end

    def initialize(tenant:, provider:, event_type:, payload:,
                   integration: nil, external_id: nil, external_type: nil,
                   headers: {}, metadata: {})
      @tenant        = tenant
      @integration   = integration
      @provider      = provider
      @event_type    = event_type
      @external_id   = external_id
      @external_type = external_type
      @payload       = payload
      @headers       = headers
      @metadata      = metadata
    end

    def call
      if (existing = find_duplicate)
        bump_duplicate_attempt(existing)
        return Result.new(true, existing, nil)
      end

      event = @tenant.integration_events.create!(
        integration:   @integration,
        provider:      @provider,
        event_type:    @event_type,
        external_id:   @external_id,
        external_type: @external_type,
        status:        "pending",
        payload:       @payload,
        headers:       @headers,
        metadata:      @metadata,
        received_at:   Time.current
      )

      Result.new(true, event, nil)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(false, nil, e.message)
    end

    private

    def find_duplicate
      return nil if @external_id.blank? || @external_type.blank?

      scope = @tenant.integration_events
        .where(event_type: @event_type, external_id: @external_id, external_type: @external_type)
      scope = scope.where(integration_id: @integration.id) if @integration
      scope.first
    end

    def bump_duplicate_attempt(event)
      attempts = event.metadata.fetch("duplicate_attempts", 0) + 1
      event.update_columns(
        metadata: event.metadata.merge("duplicate_attempts" => attempts, "last_duplicate_at" => Time.current.iso8601)
      )
    end
  end
end
