module Integrations
  module Processors
    # Handles the cart.reminder webhook (and any future cart.* event) —
    # real-time capture that complements Integrations::Yampi::CartsPollingService.
    class YampiCartProcessor
      PROVIDER = "yampi"
      Result   = Integrations::EventProcessor::Result

      def self.call(event)
        new(event).call
      end

      def initialize(event)
        @event = event
      end

      def call
        normalized = Integrations::Normalizers::YampiCartNormalizer.call(@event)

        unless normalized[:external_id].present?
          return Result.new(
            outcome:       :skipped,
            error_message: "Payload does not contain a recognizable cart identifier",
            metadata:      { payload_keys: @event.payload.keys }
          )
        end

        Channel.ensure_for!(@event.tenant, PROVIDER)
        upsert = Integrations::Carts::UpsertCart.call(
          tenant:     @event.tenant,
          normalized: normalized,
          provider:   PROVIDER
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
            cart_id:     upsert.cart.id,
            external_id: normalized[:external_id],
            status:      upsert.cart.status,
            total:       upsert.cart.total
          }
        )
      end
    end
  end
end
