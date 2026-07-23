module Integrations
  # Shopee Open Platform API v2 (Product + Order modules).
  #
  # Assinatura e base URL (produção vs sandbox via credentials
  # "environment" => "sandbox") são delegadas ao ShopeeAuthService — fonte
  # única das duas variantes de HMAC (public vs shop-level). Toda chamada
  # daqui é Shop API: shop_sign (partner_id + path + timestamp +
  # access_token + shop_id).
  #
  # Particularidades da Order API v2 (a validar contra payload sandbox
  # real — ver Shopee::OrdersPollingService):
  # - get_order_list aceita janelas de NO MÁXIMO 15 dias por request
  #   (time_from/time_to) e pagina por cursor opaco: response.more +
  #   response.next_cursor. Retorna essencialmente só order_sn; o dinheiro
  #   vem do get_order_detail.
  # - get_order_detail aceita até 50 order_sn por chamada e só devolve os
  #   campos "caros" (item_list, recipient_address, total_amount, ...) se
  #   pedidos em response_optional_fields.
  class ShopeeAdapter < BaseChannelAdapter
    ITEM_LIST_PATH = "/api/v2/product/get_item_list".freeze
    ITEM_INFO_PATH = "/api/v2/product/get_item_base_info".freeze
    MODEL_LIST_PATH = "/api/v2/product/get_model_list".freeze
    ORDER_LIST_PATH = "/api/v2/order/get_order_list".freeze
    ORDER_DETAIL_PATH = "/api/v2/order/get_order_detail".freeze
    ESCROW_DETAIL_PATH = "/api/v2/payment/get_escrow_detail".freeze

    PAGE_SIZE = 50
    ITEM_INFO_BATCH_SIZE = 50
    ORDERS_PAGE_SIZE = 50
    ORDER_DETAIL_MAX_IDS = 50
    # Limite documentado do get_order_list: time_to - time_from <= 15 dias.
    ORDER_LIST_MAX_WINDOW = 15.days

    # Campos "opcionais" do get_order_detail que o pipeline de pedidos
    # precisa (sem eles a Shopee devolve só o esqueleto do pedido).
    ORDER_DETAIL_OPTIONAL_FIELDS = %w[
      buyer_username
      recipient_address
      item_list
      pay_time
      total_amount
      estimated_shipping_fee
      actual_shipping_fee
      payment_method
      cancel_by
      cancel_reason
      buyer_cancel_reason
      invoice_data
    ].join(",").freeze

    AUTH_ERROR_KEYWORDS = %w[sign signature access_token token auth invalid_partner].freeze
    RATE_LIMIT_KEYWORDS = %w[rate frequency too many limit].freeze

    def authenticate
      get(ITEM_LIST_PATH, offset: 0, page_size: 1, item_status: "NORMAL")
      true
    end

    # 1 entrada por SKU vendável: itens com variações (has_model) são
    # expandidos via get_model_list — cada model vira uma linha própria,
    # como o TikTok faz com skus[] — e itens simples entram direto.
    def fetch_products
      item_ids = fetch_all_item_ids
      item_ids.each_slice(ITEM_INFO_BATCH_SIZE).flat_map do |batch|
        fetch_item_info(batch).flat_map { |item| expand_item_models(item) }
      end
    end

    # external_id aqui é o item_id (item sem variação) — para models o
    # bulk sync já traz o estoque no próprio fetch_products.
    def fetch_stock(external_id)
      body = get(ITEM_INFO_PATH, item_id_list: external_id)
      item = body.dig("response", "item_list")&.first || {}
      item.dig("stock_info_v2", "summary_info", "total_available_stock")
    end

    def normalize_product(raw)
      return normalize_model(raw) if raw.key?("_parent_item_id")

      {
        external_id:  raw["item_id"].to_s,
        # item_sku é opcional no Seller Centre — sem ele, cai pro item_id
        # (mesma regra do seller_sku em branco no TikTok) pra não descartar
        # o produto como "sem SKU externo".
        external_sku: raw["item_sku"].presence || raw["item_id"].to_s,
        name:         raw["item_name"],
        price:        to_decimal(raw.dig("price_info", 0, "current_price")),
        stock_qty:    to_decimal(raw.dig("stock_info_v2", "summary_info", "total_available_stock")),
        raw:          raw
      }
    end

    # A API de escrita de estoque (/api/v2/product/update_stock) existe,
    # mas o schema real (split model/item, estoque reservado de promoção,
    # seller_stock por warehouse) não foi confirmado contra uma loja real —
    # mesma regra do TikTok pré-2026-07-21: recusar explicitamente em vez
    # de arriscar um write errado silencioso.
    def update_stock(external_id:, quantity:)
      raise UnsupportedOperationError,
        "ShopeeAdapter#update_stock: escrita de estoque na Shopee ainda não foi validada " \
        "contra uma loja real (sku=#{external_id}, quantity=#{quantity})"
    end

    # Uma página do Get Order List. A lista só identifica pedidos
    # (order_sn) — os valores vêm de #fetch_order_details. Janela limitada
    # a 15 dias: o caller (OrdersPollingService) fatia janelas maiores.
    # Retorna o hash "response": { "order_list" => [...], "more" => bool,
    # "next_cursor" => "..." }.
    def fetch_orders_page(time_range_field:, time_from:, time_to:, cursor: nil, page_size: ORDERS_PAGE_SIZE)
      if time_to.to_i - time_from.to_i > ORDER_LIST_MAX_WINDOW.to_i
        raise ArgumentError,
          "ShopeeAdapter#fetch_orders_page: janela acima de 15 dias (#{time_from}..#{time_to}) — fatie antes de chamar"
      end

      body = get(
        ORDER_LIST_PATH,
        time_range_field: time_range_field,
        time_from: time_from.to_i,
        time_to: time_to.to_i,
        page_size: page_size,
        cursor: cursor.presence || "",
        response_optional_fields: "order_status"
      )
      body["response"] || {}
    end

    # Get Order Detail em batch (<= 50 order_sn). Retorna o array
    # "order_list" com os pedidos completos (item_list, total_amount etc.).
    def fetch_order_details(order_sns)
      sns = Array(order_sns).map(&:to_s).reject(&:blank?)
      return [] if sns.empty?
      if sns.size > ORDER_DETAIL_MAX_IDS
        raise ArgumentError, "ShopeeAdapter#fetch_order_details aceita no máximo #{ORDER_DETAIL_MAX_IDS} order_sn por chamada"
      end

      body = get(
        ORDER_DETAIL_PATH,
        order_sn_list: sns.join(","),
        response_optional_fields: ORDER_DETAIL_OPTIONAL_FIELDS
      )
      body.dig("response", "order_list") || []
    end

    # Detalhamento financeiro (taxas/repasse) de um pedido — Fase 4.
    # Retorna o hash "response" completo ({ order_sn, buyer_user_name,
    # return_order_sn_list, order_income => {...} }).
    def fetch_escrow_detail(order_sn)
      body = get(ESCROW_DETAIL_PATH, order_sn: order_sn.to_s)
      body["response"] || {}
    end

    private

    def auth_service
      @auth_service ||= ShopeeAuthService.new(credentials)
    end

    def fetch_all_item_ids
      ids = []
      offset = 0

      loop do
        body = get(ITEM_LIST_PATH, offset: offset, page_size: PAGE_SIZE, item_status: "NORMAL")
        page_items = body.dig("response", "item") || []
        ids.concat(page_items.map { |i| i["item_id"] })

        has_next = body.dig("response", "has_next_page")
        offset += PAGE_SIZE
        break unless has_next && page_items.any?
      end

      ids
    end

    def fetch_item_info(ids)
      body = get(ITEM_INFO_PATH, item_id_list: ids.join(","))
      body.dig("response", "item_list") || []
    end

    def expand_item_models(item)
      return [ item ] unless item["has_model"]

      models = fetch_model_list(item["item_id"])
      return [ item ] if models.empty?

      models.map do |model|
        model.merge(
          "_parent_item_id"   => item["item_id"],
          "_parent_item_name" => item["item_name"],
          "_parent_item_sku"  => item["item_sku"]
        )
      end
    end

    # get_model_list devolve os models + tier_variation (nomes das opções);
    # o nome legível da variação é montado a partir de tier_index → option.
    def fetch_model_list(item_id)
      body = get(MODEL_LIST_PATH, item_id: item_id)
      response = body["response"] || {}
      tier_variations = response["tier_variation"] || []

      (response["model"] || []).map do |model|
        model.merge("_variation_name" => variation_name_for(model, tier_variations))
      end
    end

    def variation_name_for(model, tier_variations)
      indexes = model["tier_index"]
      return model["model_name"].to_s unless indexes.is_a?(Array)

      names = indexes.each_with_index.map do |option_index, tier_position|
        tier_variations.dig(tier_position, "option_list", option_index, "option")
      end
      names.compact.join(", ").presence || model["model_name"].to_s
    end

    def normalize_model(raw)
      variation = raw["_variation_name"].presence || raw["model_name"].to_s
      parent_name = raw["_parent_item_name"].to_s
      {
        external_id:  raw["model_id"].to_s,
        external_sku: raw["model_sku"].presence || raw["model_id"].to_s,
        name:         variation.present? ? "#{parent_name} (#{variation})" : parent_name,
        price:        to_decimal(raw.dig("price_info", 0, "current_price")),
        stock_qty:    to_decimal(raw.dig("stock_info_v2", "summary_info", "total_available_stock")),
        external_product_id: raw["_parent_item_id"]&.to_s,
        raw:          raw.except("_parent_item_id", "_parent_item_name", "_parent_item_sku", "_variation_name")
      }
    end

    def get(path, **params)
      response = connection(auth_service.base_url).get(path, signed_params(path, params))
      body = handle_response(response)
      raise_on_body_error(body)
      body
    end

    # Shopee returns HTTP 200 for most application-level errors too,
    # encoding the real outcome in the response body's `error` field
    # (blank string = success). Best-effort classification into our
    # shared error types, since we don't have the real error-code table.
    def raise_on_body_error(body)
      error_code = body.is_a?(Hash) ? body["error"].to_s : ""
      return if error_code.blank?

      message = body["message"].to_s
      downcased = "#{error_code} #{message}".downcase

      if AUTH_ERROR_KEYWORDS.any? { |k| downcased.include?(k) }
        raise AuthenticationError, "ShopeeAdapter: #{message} (#{error_code})"
      elsif RATE_LIMIT_KEYWORDS.any? { |k| downcased.include?(k) }
        raise RateLimitError, "ShopeeAdapter: #{message} (#{error_code})"
      else
        raise ApiError, "ShopeeAdapter: #{message} (#{error_code})"
      end
    end

    # Parâmetros comuns de toda Shop API — assinatura delegada ao
    # ShopeeAuthService#shop_sign (fonte única, ver classe).
    def signed_params(path, extra_params)
      timestamp = Time.now.to_i
      sign = auth_service.shop_sign(
        path,
        timestamp,
        access_token: credentials[:access_token],
        shop_id: credentials[:shop_id]
      )

      extra_params.merge(
        partner_id: credentials[:partner_id],
        timestamp: timestamp,
        access_token: credentials[:access_token],
        shop_id: credentials[:shop_id],
        sign: sign
      )
    end
  end
end
