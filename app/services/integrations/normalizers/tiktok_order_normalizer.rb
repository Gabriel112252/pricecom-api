module Integrations
  module Normalizers
    class TiktokOrderNormalizer
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
        external_id = extract_external_id

        {
          external_id:    external_id,
          order_number:   @p["order_number"] || @p["order_id"]&.to_s || external_id,
          status:         extract_status,
          payment_method: extract_payment_method,
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
          gross_value:    to_f(
            @p["total_amount"] ||
            @p["total"] ||
            @p["payment_amount"] ||
            @p.dig("payment", "total_amount") ||
            @p.dig("order", "total_amount")
          ),
          freight:        to_f(
            @p["shipping_fee"] ||
            @p["freight"] ||
            @p.dig("payment", "shipping_fee")
          ),
          discount:       to_f(
            @p["discount"] ||
            @p["seller_discount"] ||
            @p["platform_discount"] ||
            @p["total_discount"] ||
            @p.dig("payment", "discount")
          ),
          ordered_at:     parse_date(@p["create_time"] || @p["created_at"]),
          items:          extract_items
        }
      end

      private

      def extract_external_id
        (@p["id"] || @p["order_id"] || @p.dig("order", "id"))&.to_s
      end

      def extract_status
        @p["status"] ||
          @p["order_status"] ||
          @p.dig("order", "status").to_s
      end

      def extract_order_type
        combined = "#{extract_status} #{@event_type}".downcase
        return "cancellation" if CANCEL_KEYWORDS.any? { |k| combined.include?(k) }
        return "refund"       if REFUND_KEYWORDS.any? { |k| combined.include?(k) }
        "sale"
      end

      def extract_payment_method
        @p.dig("payment", "method") ||
          @p["payment_method"] ||
          @p["pay_type"].to_s
      end

      def extract_customer_name
        recipient = @p.dig("recipient_address") || @p.dig("order", "recipient_address") || {}
        recipient["name"].presence ||
          @p.dig("buyer_info", "buyer_name").to_s
      end

      def extract_customer_tag
        tags = Array(@p.dig("buyer_info", "tags") || @p["tags"])
        tags.any? { |t| t.to_s.downcase.include?("recorr") } ? "recorrente" : "novo"
      end

      def extract_state
        @p.dig("recipient_address", "state") ||
          @p.dig("recipient_address", "province") ||
          @p.dig("order", "recipient_address", "state").to_s
      end

      def extract_items
        items = @p["items"] || @p["line_items"] || @p.dig("order", "items") || []
        items.map do |i|
          name = (i["product_name"] || i["name"] || i["title"]).to_s
          {
            sku:           (i["seller_sku"] || i["sku"] || i["sku_id"]).to_s,
            name:          name,
            quantity:      (i["quantity"] || i["qty"] || 1).to_i,
            unit_price:    to_f(i["sale_price"] || i["price"] || i["unit_price"]),
            unit_cost:     to_f(i["cost_price"] || i["cost"] || i["unit_cost"]),
            discount:      to_f(i["discount"] || i["seller_discount"] || i["platform_discount"]),
            is_gift:       extract_item_gift(i, name_key: "product_name", price_key: "sale_price"),
            nf_unit_price: to_f(i["nf_unit_price"] || i.dig("invoice", "unit_price"))
          }
        end
      end

      def extract_item_gift(item, name_key: "name", price_key: "price")
        return true if item["is_gift"] == true
        return true if item["gift"]    == true
        return true if item["brinde"]  == true
        name       = (item[name_key] || item["name"] || item["title"]).to_s.downcase
        unit_price = to_f(item[price_key] || item["price"] || item["unit_price"])
        unit_price == 0.0 && name.include?("brinde")
      end

      def to_f(val)
        return 0.0 if val.nil?
        val.to_s.gsub(",", ".").to_f
      end

      def parse_date(val)
        return nil if val.blank?
        return Time.zone.at(val.to_i) if val.to_s.match?(/\A\d{10,13}\z/)
        Time.zone.parse(val.to_s)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
