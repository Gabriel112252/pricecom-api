module Integrations
  module Normalizers
    # Normalizes a Yampi abandoned-cart payload — either one entry of the
    # GET /checkout/carts listing or a cart.reminder webhook "resource".
    #
    # Field reconciliation (verified against docs.yampi.com.br on
    # 2026-07-16, listing page checkout/carrinhos-abandonados/
    # listar-carrinhos-abandonados and the webhook page
    # introduction-webhook):
    #   - BOTH shapes carry totalizers.discount (aggregate discount).
    #   - The listing additionally exposes totalizers.promocode_discount_value;
    #     the webhook instead exposes totalizers.progressive_discount_value.
    #     They are different discounts (cupom vs progressivo), not two names
    #     for the same field — so both are read nil-safely and each shape
    #     just leaves the other at 0.
    #   NOTE: doc-verified only; not yet confirmed against a live API
    #   response (no real Yampi store reachable from this environment).
    class YampiCartNormalizer
      def self.call(event)
        payload = event.payload["resource"].is_a?(Hash) ? event.payload["resource"] : event.payload
        new(payload).normalize
      end

      def initialize(payload)
        @p = payload
      end

      def normalize
        {
          external_id:          (@p["id"] || @p["cart_id"])&.to_s,
          token:                @p["token"].to_s.presence,
          customer_name:        extract_customer_name,
          customer_email:       extract_customer_email,
          subtotal:             totalizer("subtotal"),
          discount:             totalizer("discount"),
          promocode_discount:   totalizer("promocode_discount_value"),
          progressive_discount: totalizer("progressive_discount_value"),
          combos_discount:      totalizer("combos_discount_value"),
          shipment_discount:    totalizer("shipment_discount_value"),
          shipment:             totalizer("shipment"),
          total:                totalizer("total"),
          abandoned_at:         parse_date(@p["updated_at"]) || parse_date(@p["created_at"]),
          raw:                  @p
        }
      end

      private

      def totalizers
        @totalizers ||= @p["totalizers"].is_a?(Hash) ? @p["totalizers"] : {}
      end

      def totalizer(key)
        to_f(totalizers[key])
      end

      def extract_customer_name
        tracking_data["name"].to_s.presence ||
          [ customer["first_name"], customer["last_name"] ].compact.join(" ").presence ||
          customer["name"].to_s.presence
      end

      def extract_customer_email
        tracking_data["email"].to_s.presence || customer["email"].to_s.presence
      end

      def tracking_data
        @tracking_data ||= @p["tracking_data"].is_a?(Hash) ? @p["tracking_data"] : {}
      end

      def customer
        @customer ||= unwrap_data(@p["customer"])
      end

      def unwrap_data(value)
        return {} unless value.is_a?(Hash)

        value["data"].is_a?(Hash) ? value["data"] : value
      end

      def to_f(val)
        return 0.0 if val.nil?
        val.to_s.gsub(",", ".").to_f
      end

      def parse_date(val)
        raw = val.is_a?(Hash) ? val["date"] : val
        return nil if raw.blank?

        Time.zone.parse(raw.to_s)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
