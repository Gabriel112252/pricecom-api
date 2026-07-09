module Integrations
  module Processors
    class YampiOrderProcessor
      Result = Integrations::EventProcessor::Result

      def self.call(event)
        new(event).call
      end

      def initialize(event)
        @event = event
      end

      def call
        normalized = Integrations::Normalizers::YampiOrderNormalizer.call(@event)

        unless normalized[:external_id].present?
          return Result.new(
            outcome:       :skipped,
            error_message: "Payload does not contain a recognizable order identifier",
            metadata:      { payload_keys: @event.payload.keys }
          )
        end

        upsert = Integrations::Orders::UpsertOrder.call(
          tenant:      @event.tenant,
          normalized:  normalized,
          integration: @event.integration,
          provider:    "yampi"
        )

        unless upsert.success?
          return Result.new(
            outcome:       :error,
            error_message: upsert.error_message,
            metadata:      { external_id: normalized[:external_id] }
          )
        end

        Result.new(
          outcome:       :success,
          error_message: nil,
          metadata: {
            order_id:     upsert.order.id,
            order_number: upsert.order.order_number,
            external_id:  normalized[:external_id],
            items_count:  upsert.order.order_items.size
          }
        )
      end
    end
  end
end
