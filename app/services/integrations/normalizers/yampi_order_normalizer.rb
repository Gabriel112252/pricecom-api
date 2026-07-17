module Integrations
  module Normalizers
    class YampiOrderNormalizer
      CANCEL_KEYWORDS = %w[cancel canceled cancelled cancelado].freeze
      REFUND_KEYWORDS = %w[refund refunded estorno reembolso chargeback].freeze

      # Yampi webhook deliveries envelope the order under a top-level
      # "resource" key ({event, time, merchant, resource: {...order...}}) —
      # see docs.yampi.com.br/api-reference/introduction-webhook. A backfill
      # pull from the Orders API returns the order hash directly (no
      # envelope), so only unwrap when "resource" is actually a Hash — a
      # bare payload must never be mistaken for one just because some other
      # provider happens to use a "resource" key for something else.
      def self.call(event)
        payload = event.payload["resource"].is_a?(Hash) ? event.payload["resource"] : event.payload
        new(payload, event.event_type).normalize
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
          # value_total/value_shipment/value_discount are the real Yampi API field
          # names (both the Orders endpoint and the webhook "resource" — see
          # docs.yampi.com.br/api-reference/pedidos and introduction-webhook);
          # total/total_freight/etc are kept as fallbacks in case a differently
          # shaped payload ever shows up.
          gross_value:    to_f(@p["total"] || @p["total_value"] || @p["value_total"]),
          freight:        to_f(@p["total_freight"] || @p["freight_value"] || @p["value_shipment"]),
          discount:       extract_discount,
          coupon_code:    extract_coupon_code,
          coupon_discount: extract_coupon_discount,
          ordered_at:     parse_date(@p["created_at"]),
          cart_token:     extract_cart_token,
          shipping_service: extract_shipping_service,
          items:          extract_items
        }
      end

      private

      def extract_id
        (@p["id"] || @p["order_id"])&.to_s
      end

      # Links a finished order back to the checkout cart it came from, so
      # UpsertOrder can flip the Cart to "converted". Verified against a
      # real production order (2026-07-16): the order payload carries a
      # flat `cart_token` string at the ROOT — the counterpart of
      # Cart#token, not of Cart#external_id. Present in the default
      # fetch_orders response, no extra include needed.
      def extract_cart_token
        @p["cart_token"].to_s.presence
      end

      # Chosen freight service. Kept for local order context/analytics; no
      # longer used to apply LucroFrete real_freight_cost, which now comes
      # from /api/reports/orders already matched by LucroFrete. CONFIRMED on
      # a real CART payload as "shipping_service" (ex:
      # "ECONOMICO_-_LOGGI_EXPRESS"); NOT yet confirmed that the ORDER
      # payload uses the same key — "shipment_service" is kept as a
      # candidate until a real order payload settles it. Confirm in
      # production and prune the wrong one.
      def extract_shipping_service
        (@p["shipping_service"] || @p["shipment_service"]).to_s.presence
      end

      def extract_status
        @p.dig("status", "alias") ||
          @p.dig("status", "data", "alias") ||
          @p.dig("status", "name") ||
          @p.dig("status", "data", "name") ||
          (@p["status"].to_s if @p["status"].is_a?(String)) ||
          "unknown"
      end

      def extract_order_type
        combined = "#{extract_status} #{@event_type}".downcase
        return "cancellation" if CANCEL_KEYWORDS.any? { |k| combined.include?(k) }
        return "refund"       if REFUND_KEYWORDS.any? { |k| combined.include?(k) }
        "sale"
      end

      def extract_customer_name
        customer = unwrap_data(@p["customer"])
        [ customer["first_name"], customer["last_name"] ].compact.join(" ").presence ||
          customer["name"].to_s
      end

      def extract_customer_tag
        tags = Array(unwrap_data(@p["customer"])["tags"] || @p["tags"])
        tags.any? { |t| t.to_s.downcase.include?("recorr") } ? "recorrente" : "novo"
      end

      def extract_state
        unwrap_data(@p["shipping_address"])["state"] ||
          extract_state_from_address ||
          @p["state"].to_s
      end

      # Yampi's Orders API returns `address` as an array (one entry per
      # saved address, per docs.yampi.com.br/api-reference/pedidos), each
      # keyed by "uf" rather than "state" — a plain Hash#dig chain across
      # that array raises TypeError, so the array has to be unwrapped
      # explicitly before reading either key.
      def extract_state_from_address
        address = @p["address"]
        address = address.first if address.is_a?(Array)
        return nil unless address.is_a?(Hash)

        address["state"] || address["uf"]
      end

      def extract_discount
        to_f(
          @p["discount"] ||
          @p["total_discount"] ||
          @p["discount_value"] ||
          @p["discounts_total"] ||
          @p["value_discount"] ||
          @p.dig("totals", "discount")
        )
      end

      # promocode chega embarcado via ?include=promocode e, pelo padrão Yampi
      # de relações embarcadas (customer/status/sku), deve vir no envelope
      # { "data" => {...} } — unwrap_data cobre as duas formas (flat ou
      # envelope). Forma exata (objeto vs array) pendente de confirmação no
      # dump TEMP(coupon-audit) de produção.
      def extract_coupon_code
        coupon_hash = unwrap_data(@p["coupon"])
        discount_coupon_hash = unwrap_data(@p["discount_coupon"])
        promocode_hash = unwrap_data(@p["promocode"])
        coupon_string = @p["coupon"] if @p["coupon"].is_a?(String)
        code = @p["coupon_code"] ||
          @p["coupon_name"] ||
          coupon_string ||
          coupon_hash["code"] ||
          coupon_hash["name"] ||
          coupon_hash["title"] ||
          discount_coupon_hash["code"] ||
          promocode_hash["code"]

        code.to_s.strip.presence
      end

      def extract_coupon_discount
        coupon_hash = unwrap_data(@p["coupon"])
        discount_coupon_hash = unwrap_data(@p["discount_coupon"])
        promocode_hash = unwrap_data(@p["promocode"])
        explicit_value = to_f(
          @p["coupon_discount"] ||
          @p["coupon_value"] ||
          coupon_hash["value"] ||
          coupon_hash["discount"] ||
          discount_coupon_hash["value"] ||
          promocode_hash["discount"]
        )
        return explicit_value if explicit_value.positive?

        extract_coupon_code.present? ? extract_discount : 0.0
      end

      # Unwraps Yampi's common `{ "data" => { ... } }` embed shape (used for
      # customer/shipping_address/status/sku in both the webhook "resource"
      # and the Orders API) down to the actual attributes hash.
      def unwrap_data(value)
        return {} unless value.is_a?(Hash)

        value["data"].is_a?(Hash) ? value["data"] : value
      end

      def extract_items
        items = @p["items"] || @p["order_items"] || []
        items = items["data"] if items.is_a?(Hash)

        Array(items).map do |i|
          {
            # item_sku is the real Yampi field for the SKU code; "sku" is a
            # nested sub-object ({ "data" => { "title" => ... } }) holding
            # the SKU's display name, not a code — only use it as a code
            # fallback if it's actually a bare String (some other shape).
            sku:           (i["item_sku"] || (i["sku"].is_a?(String) ? i["sku"] : nil)).to_s,
            name:          extract_item_name(i),
            quantity:      (i["quantity"] || i["qty"] || 1).to_i,
            unit_price:    to_f(i["original_price"] || i["unit_price"] || i["price"]),
            unit_cost:     to_f(i["cost_price"] || i["unit_cost"] || i["price_cost"]),
            discount:      to_f(i["total_discount"] || i["discount"]),
            is_gift:       extract_item_gift(i, name_key: "name", price_key: "original_price"),
            nf_unit_price: to_f(i["nf_unit_price"] || i.dig("invoice", "unit_price"))
          }
        end
      end

      # The Orders API/webhook embed the SKU's display name under
      # sku.data.title rather than a flat "name" on the item itself.
      def extract_item_name(item)
        (item["name"].presence || unwrap_data(item["sku"])["title"]).to_s
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
