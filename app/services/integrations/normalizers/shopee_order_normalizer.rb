module Integrations
  module Normalizers
    # Normalizes a Shopee order (Get Order Detail v2 —
    # /api/v2/order/get_order_detail) into the shape
    # Integrations::Orders::UpsertOrder expects.
    #
    # ⚠️ Semântica de dinheiro (a régua é o fix do TikTok de 2026-07-21 —
    # ver TiktokOrderNormalizer):
    # - gross_value é o total PRÉ-desconto: soma de model_original_price ×
    #   quantidade + frete — mesmo papel do original_total_product_price +
    #   shipping_fee do TikTok. NUNCA usar total_amount aqui: total_amount
    #   é o valor PÓS-descontos pago pelo comprador (foi exatamente esse
    #   engano que corrompeu ~29k pedidos TikTok).
    # - discount na ingestão = Σ (model_original_price −
    #   model_discounted_price) × qtd. LIMITAÇÃO CONHECIDA: o Get Order
    #   Detail não separa desconto do seller de subsídio da Shopee — essa
    #   separação só existe no escrow (order_income.seller_discount vs
    #   voucher_from_shopee/shopee_discount). Até o escrow sync validar,
    #   platform_discount fica 0 na ingestão; se o sandbox mostrar que
    #   model_discounted_price embute subsídio Shopee, a correção entra
    #   pelo escrow (Fase 4), não aqui.
    # - freight usa estimated_shipping_fee como proxy do frete pago pelo
    #   comprador (actual_shipping_fee é o custo logístico cobrado do
    #   SELLER, não entra). Validar contra
    #   order_income.buyer_paid_shipping_fee do escrow no sandbox.
    class ShopeeOrderNormalizer
      REFUND_KEYWORDS = %w[refund refunded estorno reembolso to_return].freeze

      def self.call(event)
        new(event.payload, event.event_type).normalize
      end

      def initialize(payload, event_type = "")
        @p          = payload
        @event_type = event_type.to_s.downcase
      end

      def normalize
        {
          external_id:    extract_external_id,
          # order_sn é o identificador humano que o Seller Centre mostra —
          # Shopee não tem um "número do pedido" separado.
          order_number:   extract_external_id,
          status:         extract_status,
          payment_method: @p["payment_method"].to_s,
          customer_name:  extract_customer_name,
          customer_tag:   "novo",
          state:          extract_state,
          order_type:     extract_order_type,
          refund_amount:  0.0,
          nf_number:      @p.dig("invoice_data", "number"),
          nf_gross_value: to_f(@p.dig("invoice_data", "total_value")),
          nf_discount:    0.0,
          nf_freight:     0.0,
          refund_reason:  extract_cancel_reason,
          gross_value:    extract_gross_value,
          freight:        extract_freight,
          discount:       extract_discount,
          # Sem split seller/plataforma no Get Order Detail — ver comentário
          # da classe. O escrow (Fase 4) guarda o split real em
          # financial_breakdown para auditoria.
          platform_discount: 0.0,
          coupon_code:    nil,
          coupon_discount: 0.0,
          ordered_at:     parse_unix(@p["create_time"]),
          items:          extract_items
        }
      end

      private

      def extract_external_id
        @p["order_sn"].to_s
      end

      # Enum documentado: UNPAID / READY_TO_SHIP / PROCESSED / RETRY_SHIP /
      # SHIPPED / TO_CONFIRM_RECEIVE / IN_CANCEL / CANCELLED / TO_RETURN /
      # COMPLETED / INVOICE_PENDING — armazenado verbatim, como nos outros
      # canais. Exceções: UNPAID vira o canônico "unpaid"
      # (Order::NON_REVENUE_STATUSES); CANCELLED casa com
      # Order::CANCELED_STATUS_ALIASES via LOWER sem mapeamento extra.
      def extract_status
        raw = @p["order_status"].to_s
        raw.casecmp?("unpaid") ? "unpaid" : raw
      end

      # IN_CANCEL é só uma SOLICITAÇÃO de cancelamento (pode ser negada e o
      # pedido seguir) — deliberadamente não vira order_type=cancellation;
      # quando a Shopee efetiva, o status muda pra CANCELLED e o polling
      # incremental por update_time reprocessa o pedido.
      def extract_order_type
        status = extract_status.downcase
        return "cancellation" if status == "cancelled"
        return "refund"       if REFUND_KEYWORDS.any? { |k| status.include?(k) || @event_type.include?(k) }
        "sale"
      end

      def extract_customer_name
        @p.dig("recipient_address", "name").presence || @p["buyer_username"].to_s
      end

      def extract_state
        @p.dig("recipient_address", "state").presence || @p["region"].to_s
      end

      def extract_cancel_reason
        @p["cancel_reason"].presence || @p["buyer_cancel_reason"].presence
      end

      # Total pré-desconto: produtos a preço cheio + frete (ver comentário
      # da classe). Fallback defensivo para payload sem item_list (não
      # deveria acontecer — ORDER_DETAIL_OPTIONAL_FIELDS pede item_list):
      # reconstrói a partir do total pago + desconto, como o TikTok faz.
      def extract_gross_value
        original_products_total = extract_original_products_total
        return original_products_total + extract_freight if original_products_total

        to_f(@p["total_amount"]) + extract_discount
      end

      def extract_original_products_total
        items = raw_items
        return nil if items.empty?

        items.sum do |i|
          to_f(i["model_original_price"].presence || i["model_discounted_price"]) * quantity_of(i)
        end
      end

      def extract_freight
        to_f(@p["estimated_shipping_fee"])
      end

      def extract_discount
        raw_items.sum do |i|
          original   = to_f(i["model_original_price"])
          discounted = to_f(i["model_discounted_price"])
          delta = original - discounted
          delta.positive? ? delta * quantity_of(i) : 0.0
        end
      end

      def extract_items
        raw_items.map do |i|
          {
            sku:           extract_item_sku(i),
            name:          extract_item_name(i),
            quantity:      quantity_of(i),
            # Pós-desconto por unidade — mesmo papel do sale_price do
            # TikTok; o delta pró-rata vive em :discount ao lado.
            unit_price:    to_f(i["model_discounted_price"].presence || i["model_original_price"]),
            # Shopee não expõe custo de produto; unit_cost vem do Product
            # local (ver UpsertOrder#unit_cost_for_item).
            unit_cost:     0.0,
            discount:      item_discount(i),
            is_gift:       extract_item_gift(i),
            nf_unit_price: 0.0,
            external_product_id: i["item_id"]&.to_s
          }
        end
      end

      def raw_items
        items = @p["item_list"]
        items.is_a?(Array) ? items : []
      end

      # model_sku é o SKU da variação (o que casa com Product#sku);
      # item_sku é o do produto-pai. Ambos são opcionais no Seller Centre,
      # então cai pro id da variação/produto — mesmo fallback do TikTok
      # para seller_sku em branco.
      def extract_item_sku(item)
        (item["model_sku"].presence || item["item_sku"].presence ||
          item["model_id"].presence || item["item_id"]).to_s
      end

      def extract_item_name(item)
        name = item["item_name"].to_s
        variation = item["model_name"].to_s
        variation.present? && name.present? ? "#{name} (#{variation})" : (name.presence || variation)
      end

      def quantity_of(item)
        (item["model_quantity_purchased"] || item["quantity"] || 1).to_i
      end

      def item_discount(item)
        delta = to_f(item["model_original_price"]) - to_f(item["model_discounted_price"])
        delta.positive? ? delta * quantity_of(item) : 0.0
      end

      def extract_item_gift(item)
        name       = item["item_name"].to_s.downcase
        unit_price = to_f(item["model_discounted_price"].presence || item["model_original_price"])
        unit_price == 0.0 && name.include?("brinde")
      end

      def to_f(val)
        return 0.0 if val.nil?
        val.to_s.gsub(",", ".").to_f
      end

      def parse_unix(val)
        return nil if val.blank?
        Time.zone.at(val.to_i)
      rescue TypeError
        nil
      end
    end
  end
end
