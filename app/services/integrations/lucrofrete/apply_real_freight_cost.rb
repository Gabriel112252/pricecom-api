module Integrations
  module Lucrofrete
    # Fills Order#real_freight_cost with the REAL carrier cost (cost_price)
    # of the freight option the customer actually chose, matched from the
    # LucroFrete quote recorded for the originating cart.
    #
    # Matching: Order#shipping_service (ex: "ECONOMICO_-_LOGGI_EXPRESS") is
    # tokenized (transliterate → upcase → split em não-alfanuméricos) e
    # comparado como CONJUNTO contra os tokens de cada opção da cotação
    # (slot_name + carrier_name + service, e fallback em name). Só escreve
    # quando exatamente UMA opção casa — empate ou zero matches deixa
    # real_freight_cost intocado e loga o mismatch para investigação.
    #
    # Guarda de fonte: real_freight_cost é a MESMA coluna que o sync do
    # idworks escreve. Só escrevemos quando a fonte de frete configurada do
    # tenant é "lucrofrete", para nunca corromper dado do idworks.
    class ApplyRealFreightCost
      # → true se o custo foi aplicado, false caso contrário.
      def self.call(order:, freight_quote: nil, cart: nil)
        new(order: order, freight_quote: freight_quote, cart: cart).call
      end

      def initialize(order:, freight_quote: nil, cart: nil)
        @order = order
        @freight_quote = freight_quote
        @cart = cart
      end

      def call
        return false unless order_supports_linking?
        return false unless DataSourceConfig.source_for(@order.tenant, "freight") == "lucrofrete"

        shipping_service = @order.shipping_service.to_s
        return false if shipping_service.blank?

        quote = resolve_quote
        return false unless quote

        option = match_option(quote.quote_options, shipping_service)
        unless option
          Rails.logger.warn(
            "[Integrations::Lucrofrete::ApplyRealFreightCost] sem match único para order_id=#{@order.id} " \
            "shipping_service=#{shipping_service.inspect} quote=#{quote.external_id} " \
            "opções=#{quote.quote_options.map { |o| option_label(o) }.inspect}"
          )
          return false
        end

        cost = option["cost_price"].to_f
        return false if cost <= 0
        return true if @order.real_freight_cost.to_f == cost.round(2)

        # update! (não update_column) de propósito: real_freight_cost entra
        # em effective_freight_cost, então a margem precisa recalcular.
        @order.update!(real_freight_cost: cost.round(2))
        true
      end

      private

      def order_supports_linking?
        Order.column_names.include?("shipping_service")
      end

      def resolve_quote
        return @freight_quote if @freight_quote

        cart_external_id = @cart&.external_id.to_s
        return nil if cart_external_id.blank?

        # Mais recente primeiro: se o cliente recotou o frete, a última
        # cotação é a que reflete o checkout finalizado.
        @order.tenant.freight_quotes
          .where(channel_id: @order.channel_id, cart_external_id: cart_external_id)
          .order(quoted_at: :desc, id: :desc)
          .first
      end

      def match_option(options, shipping_service)
        target = token_set(shipping_service)
        return nil if target.empty?

        exact = options.select { |o| token_set(option_label(o)) == target }
        return exact.first if exact.size == 1

        # Fallback: subconjunto (ex: pedido sem o slot_name, ou opção sem o
        # service) — só quando UMA opção satisfaz.
        subset = options.select do |o|
          tokens = token_set(option_label(o))
          tokens.any? && (tokens.subset?(target) || target.subset?(tokens))
        end
        subset.size == 1 ? subset.first : nil
      end

      def option_label(option)
        [ option["slot_name"], option["carrier_name"], option["service"] ]
          .map(&:to_s).reject(&:blank?).join(" ")
          .presence || option["name"].to_s
      end

      def token_set(value)
        I18n.transliterate(value.to_s).upcase.split(/[^A-Z0-9]+/).reject(&:empty?).to_set
      end
    end
  end
end
