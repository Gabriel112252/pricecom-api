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
  #
  # QtyAvailable/QtyReserved/QtySafetyStock/AbcCurve/InfiniteInventory/
  # LeadTimeDays/DateLastRecordModification on /sku (added 2026-07-20) are
  # confirmed via an actual /sku response captured on 2026-07-17 — NOT in
  # the Swagger spec relayed above, so field name variants beyond the
  # camelCase fallback are unverified.
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
      # idworks' Page param is 0-indexed (confirmed against production
      # 2026-07-21: Page=0 returned 441 real skus, Page=1 came back empty)
      # — starting at 1 skipped the entire first (and often only) page on
      # every tenant, silently: HTTP 200, empty array, no error anywhere.
      # This was the root cause of cost_price staying zero in
      # ProductCostSyncJob and qty_available staying zero in
      # Idworks::StockSyncJob — those services were never wrong, they just
      # never received any data to process.
      page = 0
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
      page = 0 # 0-indexed, same as #fetch_products — see that method's comment
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
        # Stock fields (confirmed via a real /sku response on 2026-07-17,
        # not the Swagger spec — Swagger didn't document these at all).
        # QtyAvailable can legitimately be negative (real overselling on
        # the ERP side) — never .abs/clamp it, that's the actual alert
        # signal Integrations::Idworks::StockSyncService needs to preserve.
        qty_available:      to_decimal(first_present(raw, "QtyAvailable", "qtyAvailable")),
        qty_reserved:       to_decimal(first_present(raw, "QtyReserved", "qtyReserved")),
        qty_safety_stock:   to_decimal(first_present(raw, "QtySafetyStock", "qtySafetyStock")),
        abc_curve:          first_present(raw, "AbcCurve", "abcCurve")&.to_s,
        lead_time_days:     first_present(raw, "LeadTimeDays", "leadTimeDays")&.to_i,
        infinite_inventory: ActiveModel::Type::Boolean.new.cast(first_present(raw, "InfiniteInventory", "infiniteInventory")),
        last_modified_at:   first_present(raw, "DateLastRecordModification", "dateLastRecordModification"),
        raw_keys:           raw.is_a?(Hash) ? raw.keys : [],
        # Full raw record, kept (unlike raw_keys elsewhere in this class)
        # so StockSyncService can store it verbatim on StockSnapshot#raw_payload
        # for audit — these are stock/fiscal-classification fields, not the
        # kind of sensitive data record_response_debug's anonymization exists
        # to protect (that's about logging unknown fields into
        # IntegrationSyncLog, a different concern from this DB-only record).
        raw:                raw.is_a?(Hash) ? raw : {}
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

    # NOT adjusted for the Page param becoming 0-indexed (2026-07-21) —
    # deliberately. Whether "TotalPages" means a page *count* (last valid
    # index = total_pages - 1) or the last valid 0-indexed page number
    # itself is still unverified (same "STILL UNVERIFIED" pagination
    # envelope this class's header already flags), and guessing wrong in
    # the count direction would truncate real pages, not just waste one
    # extra call. #fetch_products/#fetch_orders's `break if items.blank?`
    # is what actually terminates correctly regardless of that offset —
    # confirmed by the real production request that exposed this bug
    # (Page=1 came back an empty array, which is exactly what stops the
    # loop today). Leaving this comparison as-is is the safer side of an
    # unconfirmed assumption.
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
