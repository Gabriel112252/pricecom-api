module Integrations
  module Normalizers
    class YampiOrderNormalizer
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
          external_id:    extract_id,
          order_number:   @p["number"]&.to_s || @p["id"]&.to_s,
          status:         extract_status,
          payment_method: @p["payment_method"].to_s,
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
            sku:           i["sku"].to_s,
            name:          i["name"].to_s,
            quantity:      (i["quantity"] || i["qty"] || 1).to_i,
            unit_price:    to_f(i["original_price"] || i["unit_price"] || i["price"]),
            unit_cost:     to_f(i["cost_price"] || i["unit_cost"]),
            discount:      to_f(i["total_discount"] || i["discount"]),
            is_gift:       extract_item_gift(i, name_key: "name", price_key: "original_price"),
            nf_unit_price: to_f(i["nf_unit_price"] || i.dig("invoice", "unit_price"))
          }
        end
      end

      def extract_item_gift(item, name_key: "name", price_key: "price")
        return true if item["is_gift"] == true
        return true if item["gift"]    == true
        return true if item["brinde"]  == true
        name       = item[name_key].to_s.downcase
        unit_price = to_f(item[price_key] || item["unit_price"] || item["price"])
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
