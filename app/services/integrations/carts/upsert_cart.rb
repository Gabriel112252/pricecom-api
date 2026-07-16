module Integrations
  module Carts
    class UpsertCart
      Result = Struct.new(:ok, :cart, :created, :error_message, keyword_init: true) do
        def success? = ok
        def created? = created
      end

      def self.call(tenant:, normalized:, provider:)
        new(tenant: tenant, normalized: normalized, provider: provider).call
      end

      def initialize(tenant:, normalized:, provider:)
        @tenant     = tenant
        @normalized = normalized
        @provider   = provider
      end

      def call
        return Result.new(ok: false, error_message: "Carrinho sem identificador externo") if @normalized[:external_id].blank?

        channel = @tenant.channels.find_by(platform: @provider)
        return Result.new(ok: false, error_message: "Canal não encontrado para provider '#{@provider}'") unless channel

        cart = @tenant.carts.find_or_initialize_by(channel: channel, external_id: @normalized[:external_id])
        created = cart.new_record?

        cart.assign_attributes(
          token:                @normalized[:token],
          customer_name:        @normalized[:customer_name],
          customer_email:       @normalized[:customer_email],
          subtotal:             @normalized[:subtotal].to_f,
          discount:             @normalized[:discount].to_f,
          promocode_discount:   @normalized[:promocode_discount].to_f,
          progressive_discount: @normalized[:progressive_discount].to_f,
          combos_discount:      @normalized[:combos_discount].to_f,
          shipment_discount:    @normalized[:shipment_discount].to_f,
          shipment:             @normalized[:shipment].to_f,
          total:                @normalized[:total].to_f,
          abandoned_at:         @normalized[:abandoned_at] || cart.abandoned_at || Time.current,
          raw_payload:          @normalized[:raw].is_a?(Hash) ? @normalized[:raw] : {}
        )
        # A re-sync of a cart that already converted must never bounce it
        # back to "abandoned" — conversion is decided by UpsertOrder.
        cart.status = "abandoned" if cart.status.blank?
        cart.save!

        Result.new(ok: true, cart: cart, created: created)
      rescue ActiveRecord::RecordInvalid => e
        Result.new(ok: false, error_message: e.message)
      rescue => e
        Result.new(ok: false, error_message: e.message)
      end
    end
  end
end
