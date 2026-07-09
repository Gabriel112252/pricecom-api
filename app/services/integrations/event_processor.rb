module Integrations
  class EventProcessor
    Result = Struct.new(:outcome, :error_message, :metadata, keyword_init: true) do
      def success? = outcome == :success
      def skipped? = outcome == :skipped
      def error?   = outcome == :error
    end

    def self.call(event)
      new(event).call
    end

    def initialize(event)
      @event = event
    end

    def call
      provider   = @event.provider.to_s.downcase
      event_type = @event.event_type.to_s.downcase

      case provider
      when "yampi"
        if event_type.include?("order")
          Processors::YampiOrderProcessor.call(@event)
        else
          skipped("No processor configured for yampi/#{event_type}")
        end
      when "shopify"
        if event_type.include?("order")
          Processors::ShopifyOrderProcessor.call(@event)
        else
          skipped("No processor configured for shopify/#{event_type}")
        end
      when "tiktok"
        if event_type.include?("order")
          Processors::TiktokOrderProcessor.call(@event)
        else
          skipped("No processor configured for tiktok/#{event_type}")
        end
      when "idworks"
        skipped("IDWorks events are not processed yet")
      else
        skipped("No processor configured for provider/event_type: #{provider}/#{event_type}")
      end
    rescue => e
      Result.new(outcome: :error, error_message: e.message, metadata: {})
    end

    private

    def skipped(reason)
      Result.new(outcome: :skipped, error_message: reason, metadata: {})
    end
  end
end
