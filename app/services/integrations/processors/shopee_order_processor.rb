module Integrations
  module Processors
    # Espelho do TiktokOrderProcessor para pedidos Shopee (polling ou push):
    # normaliza e delega ao UpsertOrder channel-agnóstico, preservando a
    # conexão concreta da loja quando disponível.
    class ShopeeOrderProcessor
      PROVIDER = "shopee"
      Result   = Integrations::EventProcessor::Result

      def self.call(event)
        new(event).call
      end

      def initialize(event)
        @event = event
      end

      def call
        normalized = Integrations::Normalizers::ShopeeOrderNormalizer.call(@event)

        unless normalized[:external_id].present?
          return Result.new(
            outcome:       :skipped,
            error_message: "Payload does not contain a recognizable order identifier",
            metadata:      { payload_keys: @event.payload.keys }
          )
        end

        upsert = Integrations::Orders::UpsertOrder.call(
          tenant:             @event.tenant,
          normalized:         normalized,
          integration:        @event.integration,
          channel_credential: event_channel_credential,
          provider:           PROVIDER
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

      private

      def event_channel_credential
        @event.channel_credential if @event.respond_to?(:channel_credential)
      end
    end
  end
end
