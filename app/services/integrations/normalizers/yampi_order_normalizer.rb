module Integrations
  module Normalizers
    class YampiOrderNormalizer
      def self.call(event)
        new(event.payload).normalize
      end

      def initialize(payload)
        @p = payload
      end

      def normalize
        {
          external_id:    extract_id,
          order_number:   @p["number"]&.to_s || @p["id"]&.to_s,
          status:         extract_status,
          payment_method: @p["payment_method"].to_s,
          customer_name:  extract_customer_name,
          customer_tag:   extract_customer_tag,
          state:          extract_state,
          gross_value:    to_f(@p["total"] || @p["total_value"]),
          freight:        to_f(@p["total_freight"] || @p["freight_value"]),
          discount:       to_f(
            @p["discount"] ||
            @p["total_discount"] ||
            @p["discount_value"] ||
            @p["discounts_total"] ||
            @p.dig("totals", "discount")
          ),
          ordered_at:     parse_date(@p["created_at"]),
          items:          extract_items
        }
      end

      private

      def extract_id
        (@p["id"] || @p["order_id"])&.to_s
      end

      def extract_status
        @p.dig("status", "alias") ||
          @p.dig("status", "name") ||
          @p["status"]&.to_s ||
          "unknown"
      end

      def extract_customer_name
        customer = @p["customer"] || {}
        [customer["first_name"], customer["last_name"]].compact.join(" ").presence ||
          customer["name"].to_s
      end

      def extract_customer_tag
        tags = Array(@p.dig("customer", "tags") || @p["tags"])
        tags.any? { |t| t.to_s.downcase.include?("recorr") } ? "recorrente" : "novo"
      end

      def extract_state
        @p.dig("shipping_address", "state") ||
          @p.dig("address", "state") ||
          @p["state"].to_s
      end

      def extract_items
        items = @p["items"] || @p["order_items"] || []
        items.map do |i|
          {
            sku:        i["sku"].to_s,
            name:       i["name"].to_s,
            quantity:   (i["quantity"] || i["qty"] || 1).to_i,
            unit_price: to_f(i["original_price"] || i["unit_price"] || i["price"]),
            unit_cost:  to_f(i["cost_price"] || i["unit_cost"]),
            discount:   to_f(i["total_discount"] || i["discount"])
          }
        end
      end

      def to_f(val)
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
