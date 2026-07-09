module Integrations
  module Normalizers
    class TiktokOrderNormalizer
      def self.call(event)
        new(event.payload).normalize
      end

      def initialize(payload)
        @p = payload
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
          {
            sku:        (i["seller_sku"] || i["sku"] || i["sku_id"]).to_s,
            name:       (i["product_name"] || i["name"] || i["title"]).to_s,
            quantity:   (i["quantity"] || i["qty"] || 1).to_i,
            unit_price: to_f(i["sale_price"] || i["price"] || i["unit_price"]),
            unit_cost:  to_f(
              i["cost_price"] ||
              i["cost"] ||
              i["unit_cost"]
            ),
            discount:   to_f(i["discount"] || i["seller_discount"] || i["platform_discount"])
          }
        end
      end

      def to_f(val)
        return 0.0 if val.nil?
        val.to_s.gsub(",", ".").to_f
      end

      def parse_date(val)
        return nil if val.blank?
        # TikTok pode enviar timestamps Unix inteiros
        return Time.zone.at(val.to_i) if val.to_s.match?(/\A\d{10,13}\z/)
        Time.zone.parse(val.to_s)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
