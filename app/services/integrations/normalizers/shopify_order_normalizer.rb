module Integrations
  module Normalizers
    class ShopifyOrderNormalizer
      def self.call(event)
        new(event.payload).normalize
      end

      def initialize(payload)
        @p = payload
      end

      def normalize
        {
          external_id:    @p["id"]&.to_s,
          order_number:   @p["name"] || @p["order_number"]&.to_s || @p["id"]&.to_s,
          status:         extract_status,
          payment_method: @p["gateway"] || @p["payment_gateway"].to_s,
          customer_name:  extract_customer_name,
          customer_tag:   extract_customer_tag,
          state:          extract_state,
          gross_value:    to_f(@p["total_price"] || @p["subtotal_price"]),
          freight:        extract_freight,
          discount:       to_f(@p["total_discounts"]),
          ordered_at:     parse_date(@p["created_at"]),
          items:          extract_items
        }
      end

      private

      def extract_status
        @p["financial_status"] || @p["fulfillment_status"] || @p["status"].to_s
      end

      def extract_customer_name
        customer = @p["customer"] || {}
        [customer["first_name"], customer["last_name"]].compact.join(" ").presence ||
          customer["name"].to_s
      end

      def extract_customer_tag
        tags = @p.dig("customer", "tags").to_s.split(",").map(&:strip)
        tags.any? { |t| t.downcase.include?("returning") || t.downcase.include?("recorr") } ? "recorrente" : "novo"
      end

      def extract_state
        @p.dig("shipping_address", "province_code") ||
          @p.dig("shipping_address", "province") ||
          @p.dig("billing_address", "province_code").to_s
      end

      def extract_freight
        # Shopify nests freight in a price_set object
        to_f(
          @p.dig("total_shipping_price_set", "shop_money", "amount") ||
          @p["total_shipping_price"] ||
          @p["shipping_price"]
        )
      end

      def extract_items
        items = @p["line_items"] || @p["items"] || []
        items.map do |i|
          {
            sku:        i["sku"].to_s,
            name:       i["name"].to_s,
            quantity:   (i["quantity"] || 1).to_i,
            unit_price: to_f(i["price"]),
            unit_cost:  to_f(
              i["cost_price"] ||
              i["cost"] ||
              i["unit_cost"] ||
              i.dig("cost", "amount") ||
              i.dig("inventory_item", "cost")
            ),
            discount:   to_f(i["total_discount"] || i["discount_allocations"]&.sum { |d| d["amount"].to_f })
          }
        end
      end

      def to_f(val)
        return 0.0 if val.nil?
        val.to_s.gsub(",", ".").to_f
      end

      def parse_date(val)
        return nil if val.blank?
        Time.zone.parse(val.to_s)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
