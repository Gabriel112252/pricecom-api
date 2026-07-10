module Integrations
  module Normalizers
    class ShopifyOrderNormalizer
      CANCEL_KEYWORDS = %w[cancel canceled cancelled cancelado].freeze
      REFUND_KEYWORDS = %w[refund refunded estorno reembolso chargeback].freeze

      def self.call(event)
        new(event.payload, event.event_type).normalize
      end

      def initialize(payload, event_type = "")
        @p          = payload
        @event_type = event_type.to_s.downcase
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
          order_type:     extract_order_type,
          refund_amount:  to_f(
            @p["refund_amount"] ||
            @p["refunded_amount"] ||
            @p["total_refunded"] ||
            @p.dig("refund", "amount")
          ),
          nf_number:      @p["nf_number"] || @p["invoice_number"] || @p.dig("invoice", "number"),
          nf_gross_value: to_f(@p["nf_gross_value"] || @p.dig("invoice", "gross_value")),
          nf_discount:    to_f(@p["nf_discount"]    || @p.dig("invoice", "discount")),
          nf_freight:     to_f(@p["nf_freight"]     || @p.dig("invoice", "freight")),
          refund_reason:  @p["refund_reason"] || @p["reason"] || @p.dig("refund", "reason"),
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

      def extract_order_type
        combined = "#{extract_status} #{@event_type}".downcase
        return "cancellation" if CANCEL_KEYWORDS.any? { |k| combined.include?(k) }
        return "refund"       if REFUND_KEYWORDS.any? { |k| combined.include?(k) }
        "sale"
      end

      def extract_customer_name
        customer = @p["customer"] || {}
        [ customer["first_name"], customer["last_name"] ].compact.join(" ").presence ||
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
            sku:           i["sku"].to_s,
            name:          i["name"].to_s,
            quantity:      (i["quantity"] || 1).to_i,
            unit_price:    to_f(i["price"]),
            unit_cost:     to_f(
              i["cost_price"] ||
              i["cost"] ||
              i["unit_cost"] ||
              i.dig("cost", "amount") ||
              i.dig("inventory_item", "cost")
            ),
            discount:      to_f(i["total_discount"] || i["discount_allocations"]&.sum { |d| d["amount"].to_f }),
            is_gift:       extract_item_gift(i, name_key: "name", price_key: "price"),
            nf_unit_price: to_f(i["nf_unit_price"] || i.dig("invoice", "unit_price"))
          }
        end
      end

      def extract_item_gift(item, name_key: "name", price_key: "price")
        return true if item["is_gift"] == true
        return true if item["gift"]    == true
        return true if item["brinde"]  == true
        name       = item[name_key].to_s.downcase
        unit_price = to_f(item[price_key] || item["unit_price"])
        unit_price == 0.0 && name.include?("brinde")
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
