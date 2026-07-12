require "digest"

module Integrations
  # idworks (ERP) adapter — CONFIRMED against the tenant's real idworks
  # Swagger spec (swagger.idworks.com.br) on 2026-07-10: base URL
  # https://hidrabene.api-idworks.com.br/1.0/, GET /sku (paginated product
  # list, "Page" param), GET /orders (paginated, DateFrom/DateTo filters).
  # Auth is delegated entirely to Idworks::BaseClient/Idworks::AuthService
  # (POST user/signin/local -> Bearer token + Origin/FilePath headers on
  # every call) rather than reimplemented here.
  #
  # STILL UNVERIFIED (not covered in the Swagger fields relayed to this
  # environment — confirm before trusting in production):
  #   - the exact pagination response envelope. The parser now accepts a
  #     bare array, common wrappers such as Data/Items/Records/Results, and
  #     nested paginated objects, while logging the real envelope safely in
  #     IntegrationSyncLog metadata for confirmation.
  #   - the plain SKU-code field name on /sku records: guessed as "Sku"
  #     (falling back to IDSku). Note Product#idworks_id already exists as
  #     a column but nothing currently reads/writes it — IDSku might be the
  #     intended match key instead of the sku string; out of scope to
  #     change here without being asked, but worth revisiting.
  #   - DateFrom/DateTo's exact format/timezone for GET /orders — assumed
  #     full ISO8601 timestamps (a date-only filter would be useless for
  #     OrderSyncService's 2-hour polling window).
  class IdworksAdapter < BaseErpAdapter
    COLLECTION_KEYS = %w[
      Data data Items items Records records Results results List list Rows rows
      SKUs skus Sku sku
    ].freeze
    PAGINATION_KEYS = %w[
      Page page CurrentPage currentPage PageNumber pageNumber PageSize pageSize
      TotalPages totalPages Pages pages Total total TotalCount totalCount
      TotalRecords totalRecords HasNextPage hasNextPage NextPage nextPage
    ].freeze
    MAX_PAGES = 1_000

    attr_reader :product_response_debug, :order_response_debug

    def initialize(credentials)
      super
      @client = Idworks::BaseClient.new(credentials)
      @product_response_debug = []
      @order_response_debug = []
    end

    def authenticate
      client.authenticate!
    end

    # → [{ idworks_id:, sku:, cost_last_purchase:, cost_average: }]
    def fetch_products
      products = []
      page = 1
      @product_response_debug = []

      loop do
        body  = with_rate_limit_retry { client.get("sku", "Page" => page) }
        collection = extract_collection(body)
        items = collection[:items]
        record_response_debug(
          product_response_debug,
          endpoint: "sku",
          page: page,
          body: body,
          collection: collection
        )
        break if items.blank?

        products.concat(items.map { |raw| normalize_product(raw) })
        break if last_page?(collection[:pagination], page)

        page += 1
        break if page > MAX_PAGES
      end

      products
    end

    # → [{ order_ref:, idworks_order_id:, value_shipping:, value_product:,
    #      value_order:, value_paid: }]
    def fetch_orders(from:, to:)
      orders = []
      page = 1
      @order_response_debug = []

      loop do
        body = with_rate_limit_retry do
          client.get("orders", "Page" => page, "DateFrom" => from.iso8601, "DateTo" => to.iso8601)
        end
        collection = extract_collection(body)
        items = collection[:items]
        record_response_debug(
          order_response_debug,
          endpoint: "orders",
          page: page,
          body: body,
          collection: collection
        )
        break if items.blank?

        orders.concat(items.map { |raw| normalize_order(raw) })
        break if last_page?(collection[:pagination], page)

        page += 1
        break if page > MAX_PAGES
      end

      orders
    end

    private

    attr_reader :client

    def extract_collection(body, path = [])
      return { items: body, pagination: {}, path: path } if body.is_a?(Array)
      return { items: [], pagination: {}, path: path } unless body.is_a?(Hash)

      pagination = extract_pagination(body)

      COLLECTION_KEYS.each do |key|
        next unless body.key?(key)

        value = body[key]
        if value.is_a?(Array)
          return { items: value, pagination: pagination, path: path + [ key ] }
        end

        if value.is_a?(Hash)
          nested = extract_collection(value, path + [ key ])
          return nested.merge(pagination: pagination.merge(nested[:pagination])) if nested[:items].present?
        end
      end

      array_key, array_value = body.find { |_key, value| value.is_a?(Array) }
      return { items: array_value, pagination: pagination, path: path + [ array_key ] } if array_value

      body.each do |key, value|
        next unless value.is_a?(Hash)

        nested = extract_collection(value, path + [ key ])
        return nested.merge(pagination: pagination.merge(nested[:pagination])) if nested[:items].present?
      end

      { items: [], pagination: pagination, path: path }
    end

    def normalize_product(raw)
      {
        idworks_id:         first_present(raw, "IDSku", "IDSKU", "idSku", "id_sku", "SkuId", "skuId")&.to_s,
        sku:                first_present(raw, "Sku", "SKU", "sku", "Code", "code", "ProductCode", "Reference", "reference")&.to_s,
        cost_last_purchase: to_decimal(first_present(raw, "CostLastPurchase", "costLastPurchase", "lastPurchaseCost", "LastPurchaseCost")),
        cost_average:       to_decimal(first_present(raw, "CostAverage", "costAverage", "AverageCost", "averageCost")),
        raw_keys:           raw.is_a?(Hash) ? raw.keys : []
      }
    end

    def normalize_order(raw)
      {
        order_ref:        first_present(raw, "Order", "order", "OrderNumber", "orderNumber", "ExternalOrder", "externalOrder")&.to_s,
        idworks_order_id: first_present(raw, "IDOrder", "IDORDER", "idOrder", "id_order", "OrderId", "orderId")&.to_s,
        value_shipping:   to_decimal(first_present(raw, "ValueShipping", "valueShipping", "ShippingValue", "shippingValue", "FreightValue", "freightValue")),
        value_product:    to_decimal(first_present(raw, "ValueProduct", "valueProduct")),
        value_order:      to_decimal(first_present(raw, "ValueOrder", "valueOrder")),
        value_paid:       to_decimal(first_present(raw, "ValuePaid", "valuePaid")),
        raw_keys:         raw.is_a?(Hash) ? raw.keys : []
      }
    end

    def extract_pagination(body)
      body.slice(*PAGINATION_KEYS)
    end

    def last_page?(pagination, page)
      total_pages = first_present(pagination, "TotalPages", "totalPages", "Pages", "pages").to_i
      return true if total_pages.positive? && page >= total_pages

      has_next = first_present(pagination, "HasNextPage", "hasNextPage")
      return true if has_next == false

      false
    end

    def record_response_debug(debug, endpoint:, page:, body:, collection:)
      return if debug.size >= 10

      items = collection[:items]
      debug << {
        endpoint: endpoint,
        http_status: client.last_response&.status,
        response_class: body.class.name,
        top_level_keys: body.is_a?(Hash) ? body.keys : nil,
        collection_path: collection[:path],
        received_count: items.size,
        first_record: anonymized_record(items.first),
        pagination: collection[:pagination]
      }
      Rails.logger.info("[IDWorks] #{endpoint} response_debug #{debug.last.inspect}")
    end

    def anonymized_record(record)
      return nil if record.nil?
      return { "_class" => record.class.name } unless record.is_a?(Hash)

      record.transform_values { |value| anonymized_value(value) }
    end

    def anonymized_value(value)
      case value
      when String
        {
          type: "String",
          present: value.present?,
          length: value.length,
          sha256_prefix: Digest::SHA256.hexdigest(value)[0, 10]
        }
      when Numeric
        { type: value.class.name, present: true }
      when NilClass
        nil
      when TrueClass, FalseClass
        { type: "Boolean", value: value }
      else
        { type: value.class.name, present: value.present? }
      end
    end

    def first_present(hash, *keys)
      return nil unless hash.respond_to?(:key?)

      keys.each do |key|
        return hash[key] if hash.key?(key) && !hash[key].nil?
      end
      nil
    end
  end
end
