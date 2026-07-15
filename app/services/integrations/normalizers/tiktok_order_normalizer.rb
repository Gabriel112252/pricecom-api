module Integrations
  module Normalizers
    # Normalizes a TikTok Shop order (Get Order List / Get Order Detail
    # 202309 — partner.tiktokshop.com/docv2/page/get-order-list-202309)
    # into the shape Integrations::Orders::UpsertOrder expects. The
    # doc-verified fields come first in each extractor; the extra fallbacks
    # are kept for defensively handling webhook-shaped payloads.
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
          # TikTok has no separate human-facing order number; the order id
          # is what Seller Center shows.
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
          # gross_value must be the PRE-discount order total: the rest of
          # the system (Order#calculate_margin, dashboard) subtracts
          # `discount` from it. payment.total_amount is the POST-discount
          # amount the buyer paid (doc: total_amount = sub_total +
          # shipping_fee + taxes, where sub_total is already net of
          # seller/platform discounts) — storing it here double-counted the
          # discount and produced discount > gross_value in production.
          # Identity kept (taxes are zero outside US/cross-border):
          #   gross_value - discount == payment.total_amount - taxes
          gross_value:    extract_gross_value,
          freight:        extract_freight,
          discount:       extract_discount,
          coupon_code:    extract_coupon_code,
          coupon_discount: extract_coupon_discount,
          ordered_at:     parse_date(@p["create_time"] || @p["created_at"]),
          items:          extract_items
        }
      end

      private

      def extract_external_id
        (@p["id"] || @p["order_id"] || @p.dig("order", "id"))&.to_s
      end

      # Doc enum: UNPAID / ON_HOLD / AWAITING_SHIPMENT / PARTIALLY_SHIPPING
      # / AWAITING_COLLECTION / IN_TRANSIT / DELIVERED / COMPLETED /
      # CANCELLED — stored verbatim, like the other channels.
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
        @p["payment_method_name"] ||
          @p.dig("payment", "method") ||
          @p["payment_method"] ||
          @p["pay_type"].to_s
      end

      # recipient_address is absent for UNPAID/ON_HOLD orders, and the name
      # is desensitized when platform logistics is used — both acceptable
      # for dashboard purposes.
      def extract_customer_name
        recipient = @p.dig("recipient_address") || @p.dig("order", "recipient_address") || {}
        recipient["name"].presence ||
          @p["buyer_nickname"].presence ||
          @p.dig("buyer_info", "buyer_name").to_s
      end

      def extract_customer_tag
        tags = Array(@p.dig("buyer_info", "tags") || @p["tags"])
        tags.any? { |t| t.to_s.downcase.include?("recorr") } ? "recorrente" : "novo"
      end

      # There is no flat `state` key in the 202309 address schema: the
      # administrative divisions live in recipient_address.district_info[]
      # ({address_level_name, address_name, address_level}), with
      # region_code as the country-level fallback.
      def extract_state
        @p.dig("recipient_address", "state").presence ||
          @p.dig("recipient_address", "province").presence ||
          extract_state_from_district_info.presence ||
          @p.dig("recipient_address", "region_code").to_s
      end

      def extract_state_from_district_info
        districts = @p.dig("recipient_address", "district_info")
        return nil unless districts.is_a?(Array)

        named = districts.find { |d| d["address_level_name"].to_s.match?(/state|province|estado/i) }
        leveled = districts.find { |d| d["address_level"].to_s == "L1" }
        (named || leveled)&.dig("address_name")
      end

      # Pre-discount order total: original_total_product_price (doc: "Total
      # original price of the products") + the buyer-paid shipping fee —
      # the same "products + freight, before product discounts" semantics
      # Yampi's value_total carries into gross_value.
      def extract_gross_value
        original_products_total = extract_original_products_total
        return original_products_total + extract_freight if original_products_total

        # Unknown payload shape without pre-discount info: rebuild the
        # pre-discount gross from the paid total + discounts so the margin
        # math (gross - discount) still lands on what the buyer paid.
        extract_paid_total + extract_discount
      end

      def extract_original_products_total
        payment = payment_hash
        return to_f(payment["original_total_product_price"]) if payment && payment["original_total_product_price"].present?

        line_items = raw_line_items
        return nil unless line_items.any? { |i| i["original_price"].present? }

        line_items.sum { |i| to_f(i["original_price"].presence || i["sale_price"]) * (i["quantity"] || 1).to_i }
      end

      def extract_paid_total
        to_f(
          @p.dig("payment", "total_amount") ||
          @p["total_amount"] ||
          @p["total"] ||
          @p["payment_amount"] ||
          @p.dig("order", "total_amount")
        )
      end

      def extract_freight
        to_f(
          @p.dig("payment", "shipping_fee") ||
          @p["shipping_fee"] ||
          @p["freight"]
        )
      end

      # payment.seller_discount / payment.platform_discount are the
      # product-level discounts (shipping discounts are already reflected
      # in payment.shipping_fee).
      def extract_discount
        payment = payment_hash
        return to_f(payment["seller_discount"]) + to_f(payment["platform_discount"]) if payment

        to_f(
          @p["discount"] ||
          @p["seller_discount"] ||
          @p["platform_discount"] ||
          @p["total_discount"]
        )
      end

      def payment_hash
        @p["payment"].is_a?(Hash) ? @p["payment"] : nil
      end

      def extract_coupon_code
        coupon_hash = @p["coupon"].is_a?(Hash) ? @p["coupon"] : {}
        voucher_hash = @p["voucher"].is_a?(Hash) ? @p["voucher"] : {}
        promotion_hash = @p["promotion"].is_a?(Hash) ? @p["promotion"] : {}
        coupon_string = @p["coupon"] if @p["coupon"].is_a?(String)
        voucher_string = @p["voucher"] if @p["voucher"].is_a?(String)
        code = @p["coupon_code"] ||
          @p["voucher_code"] ||
          coupon_string ||
          voucher_string ||
          coupon_hash["code"] ||
          voucher_hash["code"] ||
          @p.dig("payment", "coupon_code") ||
          promotion_hash["code"]

        code.to_s.strip.presence
      end

      def extract_coupon_discount
        coupon_hash = @p["coupon"].is_a?(Hash) ? @p["coupon"] : {}
        voucher_hash = @p["voucher"].is_a?(Hash) ? @p["voucher"] : {}
        promotion_hash = @p["promotion"].is_a?(Hash) ? @p["promotion"] : {}
        explicit_value = to_f(
          @p["coupon_discount"] ||
          @p["voucher_discount"] ||
          coupon_hash["discount"] ||
          voucher_hash["discount"] ||
          @p.dig("payment", "coupon_discount") ||
          promotion_hash["discount"]
        )
        return explicit_value if explicit_value.positive?

        extract_coupon_code.present? ? extract_discount : 0.0
      end

      # line_items has no quantity field: each entry is exactly one unit of
      # a SKU (buying 3x the same SKU yields 3 line items), so units are
      # grouped back into one item with a summed quantity. Per-unit fields
      # per the doc: sku_id, seller_sku, product_id, product_name, sku_name,
      # sale_price, original_price, seller_discount, platform_discount,
      # is_gift.
      def extract_items
        raw_line_items.group_by { |i| item_group_key(i) }.map do |_key, units|
          i = units.first
          {
            sku:           (i["seller_sku"].presence || i["sku_id"] || i["sku"]).to_s,
            name:          extract_item_name(i),
            quantity:      units.sum { |unit| (unit["quantity"] || 1).to_i },
            unit_price:    to_f(i["sale_price"] || i["price"] || i["unit_price"]),
            # TikTok doesn't expose product cost; unit_cost comes from the
            # local Product (see UpsertOrder#unit_cost_for_item).
            unit_cost:     to_f(i["cost_price"] || i["cost"] || i["unit_cost"]),
            discount:      units.sum { |unit| to_f(unit["seller_discount"]) + to_f(unit["platform_discount"]) },
            is_gift:       extract_item_gift(i, name_key: "product_name", price_key: "sale_price"),
            nf_unit_price: to_f(i["nf_unit_price"] || i.dig("invoice", "unit_price")),
            external_product_id: i["product_id"]&.to_s
          }
        end
      end

      def raw_line_items
        @p["line_items"] || @p["items"] || @p.dig("order", "items") || []
      end

      def item_group_key(item)
        sku_key = item["sku_id"].presence || item["seller_sku"].presence || item["id"].presence || item.object_id
        [ sku_key, item["sale_price"].to_s, item["is_gift"] == true ]
      end

      def extract_item_name(item)
        name = (item["product_name"].presence || item["name"].presence || item["title"]).to_s
        name.presence || item["sku_name"].to_s
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
