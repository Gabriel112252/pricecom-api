# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.2].define(version: 2026_07_17_010100) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "audit_conflicts", force: :cascade do |t|
    t.bigint "tenant_id", null: false
    t.bigint "order_id"
    t.bigint "product_id"
    t.string "conflict_type", null: false
    t.string "severity", default: "medium", null: false
    t.string "status", default: "open", null: false
    t.decimal "expected_value", precision: 10, scale: 2, default: "0.0", null: false
    t.decimal "actual_value", precision: 10, scale: 2, default: "0.0", null: false
    t.decimal "difference", precision: 10, scale: 2, default: "0.0", null: false
    t.string "source", default: "auto", null: false
    t.text "notes"
    t.datetime "resolved_at"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "resolved_by_id"
    t.index ["created_at"], name: "index_audit_conflicts_on_created_at"
    t.index ["order_id"], name: "index_audit_conflicts_on_order_id"
    t.index ["product_id"], name: "index_audit_conflicts_on_product_id"
    t.index ["resolved_by_id"], name: "index_audit_conflicts_on_resolved_by_id"
    t.index ["tenant_id", "conflict_type"], name: "index_audit_conflicts_on_tenant_id_and_conflict_type"
    t.index ["tenant_id", "severity"], name: "index_audit_conflicts_on_tenant_id_and_severity"
    t.index ["tenant_id", "status"], name: "index_audit_conflicts_on_tenant_id_and_status"
    t.index ["tenant_id"], name: "index_audit_conflicts_on_tenant_id"
  end

  create_table "carts", force: :cascade do |t|
    t.bigint "tenant_id", null: false
    t.bigint "channel_id", null: false
    t.string "external_id", null: false
    t.string "token"
    t.string "customer_name"
    t.string "customer_email"
    t.decimal "subtotal", precision: 12, scale: 2, default: "0.0", null: false
    t.decimal "discount", precision: 12, scale: 2, default: "0.0", null: false
    t.decimal "promocode_discount", precision: 12, scale: 2, default: "0.0", null: false
    t.decimal "progressive_discount", precision: 12, scale: 2, default: "0.0", null: false
    t.decimal "combos_discount", precision: 12, scale: 2, default: "0.0", null: false
    t.decimal "shipment_discount", precision: 12, scale: 2, default: "0.0", null: false
    t.decimal "shipment", precision: 12, scale: 2, default: "0.0", null: false
    t.decimal "total", precision: 12, scale: 2, default: "0.0", null: false
    t.string "status", default: "abandoned", null: false
    t.bigint "converted_order_id"
    t.datetime "abandoned_at"
    t.jsonb "raw_payload", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["channel_id"], name: "index_carts_on_channel_id"
    t.index ["converted_order_id"], name: "index_carts_on_converted_order_id"
    t.index ["tenant_id", "abandoned_at"], name: "index_carts_on_tenant_id_and_abandoned_at"
    t.index ["tenant_id", "channel_id", "external_id"], name: "index_carts_on_tenant_id_and_channel_id_and_external_id", unique: true
    t.index ["tenant_id", "status"], name: "index_carts_on_tenant_id_and_status"
    t.index ["tenant_id"], name: "index_carts_on_tenant_id"
    t.index ["token"], name: "index_carts_on_token"
  end

  create_table "channel_credentials", force: :cascade do |t|
    t.bigint "tenant_id", null: false
    t.string "channel", null: false
    t.jsonb "credentials", default: {}, null: false
    t.string "status", default: "pending", null: false
    t.datetime "last_synced_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "role", default: 2, null: false
    t.bigint "stock_source_channel_id"
    t.datetime "orders_sync_cursor_at"
    t.boolean "polling_enabled", default: false, null: false
    t.datetime "carts_sync_cursor_at"
    t.index ["stock_source_channel_id"], name: "index_channel_credentials_on_stock_source_channel_id"
    t.index ["tenant_id", "channel"], name: "index_channel_credentials_on_tenant_id_and_channel", unique: true
    t.index ["tenant_id"], name: "index_channel_credentials_on_tenant_id"
  end

  create_table "channel_operational_costs", force: :cascade do |t|
    t.bigint "product_id", null: false
    t.bigint "channel_id", null: false
    t.decimal "cost", precision: 10, scale: 2, default: "0.0"
    t.string "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["channel_id"], name: "index_channel_operational_costs_on_channel_id"
    t.index ["product_id", "channel_id"], name: "index_channel_operational_costs_on_product_id_and_channel_id", unique: true
    t.index ["product_id"], name: "index_channel_operational_costs_on_product_id"
  end

  create_table "channel_product_listings", force: :cascade do |t|
    t.bigint "product_id", null: false
    t.bigint "tenant_id", null: false
    t.string "channel", null: false
    t.string "external_id"
    t.string "external_sku"
    t.decimal "stock_qty", precision: 12, scale: 3
    t.decimal "price", precision: 10, scale: 2
    t.jsonb "raw_payload", default: {}
    t.datetime "synced_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["product_id"], name: "index_channel_product_listings_on_product_id"
    t.index ["tenant_id", "channel", "external_id"], name: "idx_on_tenant_id_channel_external_id_a1d176e2c8", unique: true
    t.index ["tenant_id"], name: "index_channel_product_listings_on_tenant_id"
  end

  create_table "channels", force: :cascade do |t|
    t.bigint "tenant_id", null: false
    t.string "name", null: false
    t.string "platform", null: false
    t.decimal "commission_pct", precision: 5, scale: 2, default: "0.0"
    t.decimal "commission_fixed", precision: 10, scale: 2, default: "0.0"
    t.string "commission_source", default: "manual"
    t.jsonb "credentials", default: {}
    t.boolean "active", default: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "platform"], name: "index_channels_on_tenant_id_and_platform"
    t.index ["tenant_id"], name: "index_channels_on_tenant_id"
  end

  create_table "data_source_configs", force: :cascade do |t|
    t.bigint "tenant_id", null: false
    t.string "data_type", null: false
    t.string "source", null: false
    t.boolean "enabled", default: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "data_type"], name: "index_data_source_configs_on_tenant_id_and_data_type", unique: true
    t.index ["tenant_id"], name: "index_data_source_configs_on_tenant_id"
  end

  create_table "financial_receivables", force: :cascade do |t|
    t.bigint "tenant_id", null: false
    t.bigint "financial_source_id", null: false
    t.bigint "financial_settlement_item_id"
    t.bigint "order_id"
    t.string "payable_id", null: false
    t.string "status", null: false
    t.decimal "amount", precision: 12, scale: 2, default: "0.0", null: false
    t.decimal "fee_amount", precision: 12, scale: 2, default: "0.0", null: false
    t.decimal "anticipation_fee_amount", precision: 12, scale: 2, default: "0.0", null: false
    t.decimal "net_amount", precision: 12, scale: 2, default: "0.0", null: false
    t.integer "installment"
    t.string "transaction_id"
    t.string "charge_id"
    t.string "recipient_id"
    t.string "payment_method"
    t.date "payment_date"
    t.date "original_payment_date"
    t.datetime "accrual_date"
    t.datetime "date_created"
    t.jsonb "raw_payload", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["charge_id"], name: "index_financial_receivables_on_charge_id"
    t.index ["financial_settlement_item_id"], name: "index_financial_receivables_on_financial_settlement_item_id"
    t.index ["financial_source_id", "payment_date"], name: "idx_financial_receivables_on_source_payment_date"
    t.index ["financial_source_id"], name: "index_financial_receivables_on_financial_source_id"
    t.index ["order_id"], name: "index_financial_receivables_on_order_id"
    t.index ["payment_method"], name: "index_financial_receivables_on_payment_method"
    t.index ["tenant_id", "financial_source_id", "payable_id"], name: "idx_financial_receivables_on_source_payable", unique: true
    t.index ["tenant_id", "payment_date", "status"], name: "idx_financial_receivables_on_tenant_payment_status"
    t.index ["tenant_id"], name: "index_financial_receivables_on_tenant_id"
    t.index ["transaction_id"], name: "index_financial_receivables_on_transaction_id"
  end

  create_table "financial_settlement_items", force: :cascade do |t|
    t.bigint "tenant_id", null: false
    t.bigint "financial_settlement_id", null: false
    t.bigint "order_id"
    t.string "external_id"
    t.string "external_order_id"
    t.string "transaction_type", default: "sale"
    t.decimal "gross_amount", precision: 12, scale: 2, default: "0.0"
    t.decimal "fee_amount", precision: 12, scale: 2, default: "0.0"
    t.decimal "discount_amount", precision: 12, scale: 2, default: "0.0"
    t.decimal "refund_amount", precision: 12, scale: 2, default: "0.0"
    t.decimal "chargeback_amount", precision: 12, scale: 2, default: "0.0"
    t.decimal "net_amount", precision: 12, scale: 2, default: "0.0"
    t.decimal "expected_amount", precision: 12, scale: 2, default: "0.0"
    t.decimal "difference_amount", precision: 12, scale: 2, default: "0.0"
    t.string "status", default: "unmatched"
    t.datetime "transaction_date"
    t.date "payout_date"
    t.jsonb "metadata", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.decimal "expected_fee_amount", precision: 12, scale: 2
    t.decimal "fee_difference_amount", precision: 12, scale: 2
    t.index ["external_order_id"], name: "index_financial_settlement_items_on_external_order_id"
    t.index ["financial_settlement_id", "status"], name: "idx_financial_settlement_items_on_settlement_id_and_status"
    t.index ["financial_settlement_id"], name: "index_financial_settlement_items_on_financial_settlement_id"
    t.index ["metadata"], name: "index_financial_settlement_items_on_metadata", using: :gin
    t.index ["order_id"], name: "index_financial_settlement_items_on_order_id"
    t.index ["tenant_id", "status"], name: "index_financial_settlement_items_on_tenant_id_and_status"
    t.index ["tenant_id"], name: "index_financial_settlement_items_on_tenant_id"
    t.index ["transaction_date"], name: "index_financial_settlement_items_on_transaction_date"
  end

  create_table "financial_settlements", force: :cascade do |t|
    t.bigint "tenant_id", null: false
    t.bigint "financial_source_id", null: false
    t.bigint "integration_id"
    t.bigint "channel_id"
    t.string "external_id"
    t.date "period_start"
    t.date "period_end"
    t.decimal "gross_amount", precision: 12, scale: 2, default: "0.0"
    t.decimal "fee_amount", precision: 12, scale: 2, default: "0.0"
    t.decimal "discount_amount", precision: 12, scale: 2, default: "0.0"
    t.decimal "refund_amount", precision: 12, scale: 2, default: "0.0"
    t.decimal "chargeback_amount", precision: 12, scale: 2, default: "0.0"
    t.decimal "net_amount", precision: 12, scale: 2, default: "0.0"
    t.date "expected_payout_date"
    t.date "actual_payout_date"
    t.string "status", default: "pending"
    t.jsonb "metadata", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["channel_id"], name: "index_financial_settlements_on_channel_id"
    t.index ["external_id"], name: "index_financial_settlements_on_external_id"
    t.index ["financial_source_id", "status"], name: "index_financial_settlements_on_financial_source_id_and_status"
    t.index ["financial_source_id"], name: "index_financial_settlements_on_financial_source_id"
    t.index ["integration_id"], name: "index_financial_settlements_on_integration_id"
    t.index ["metadata"], name: "index_financial_settlements_on_metadata", using: :gin
    t.index ["tenant_id", "expected_payout_date"], name: "idx_financial_settlements_on_tenant_id_and_expected_payout_date"
    t.index ["tenant_id", "period_start"], name: "index_financial_settlements_on_tenant_id_and_period_start"
    t.index ["tenant_id", "status"], name: "index_financial_settlements_on_tenant_id_and_status"
    t.index ["tenant_id"], name: "index_financial_settlements_on_tenant_id"
  end

  create_table "financial_sources", force: :cascade do |t|
    t.bigint "tenant_id", null: false
    t.bigint "integration_id"
    t.bigint "channel_id"
    t.string "provider", null: false
    t.string "name", null: false
    t.string "source_type", default: "gateway", null: false
    t.string "status", default: "active", null: false
    t.jsonb "settings", default: {}, null: false
    t.jsonb "credentials", default: {}, null: false
    t.boolean "active", default: true, null: false
    t.datetime "last_synced_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["channel_id"], name: "index_financial_sources_on_channel_id"
    t.index ["integration_id"], name: "index_financial_sources_on_integration_id"
    t.index ["settings"], name: "index_financial_sources_on_settings", using: :gin
    t.index ["tenant_id", "provider", "name"], name: "index_financial_sources_on_tenant_id_and_provider_and_name", unique: true
    t.index ["tenant_id", "provider"], name: "index_financial_sources_on_tenant_id_and_provider"
    t.index ["tenant_id", "source_type"], name: "index_financial_sources_on_tenant_id_and_source_type"
    t.index ["tenant_id", "status"], name: "index_financial_sources_on_tenant_id_and_status"
    t.index ["tenant_id"], name: "index_financial_sources_on_tenant_id"
  end

  create_table "freight_margin_dailies", force: :cascade do |t|
    t.bigint "tenant_id", null: false
    t.bigint "channel_id", null: false
    t.date "date", null: false
    t.integer "order_count", default: 0, null: false
    t.decimal "freight_charged", precision: 12, scale: 2, default: "0.0", null: false
    t.decimal "freight_cost", precision: 12, scale: 2, default: "0.0", null: false
    t.decimal "margin_value", precision: 12, scale: 2, default: "0.0", null: false
    t.decimal "margin_percent", precision: 8, scale: 2
    t.integer "free_shipping_count"
    t.datetime "synced_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["channel_id"], name: "index_freight_margin_dailies_on_channel_id"
    t.index ["tenant_id", "channel_id", "date"], name: "idx_on_tenant_id_channel_id_date_905468f3a5", unique: true
    t.index ["tenant_id", "date"], name: "index_freight_margin_dailies_on_tenant_id_and_date"
    t.index ["tenant_id"], name: "index_freight_margin_dailies_on_tenant_id"
  end

  create_table "freight_quotes", force: :cascade do |t|
    t.bigint "tenant_id", null: false
    t.bigint "channel_id", null: false
    t.string "external_id", null: false
    t.string "cart_external_id"
    t.string "origin_cep"
    t.string "destination_cep"
    t.string "destination_state"
    t.integer "total_weight_grams"
    t.datetime "quoted_at"
    t.jsonb "quotes", default: [], null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["channel_id"], name: "index_freight_quotes_on_channel_id"
    t.index ["tenant_id", "cart_external_id"], name: "index_freight_quotes_on_tenant_id_and_cart_external_id"
    t.index ["tenant_id", "external_id"], name: "index_freight_quotes_on_tenant_id_and_external_id", unique: true
    t.index ["tenant_id", "quoted_at"], name: "index_freight_quotes_on_tenant_id_and_quoted_at"
    t.index ["tenant_id"], name: "index_freight_quotes_on_tenant_id"
  end

  create_table "imports", force: :cascade do |t|
    t.bigint "tenant_id", null: false
    t.bigint "channel_id"
    t.string "filename"
    t.string "status", default: "pending"
    t.integer "total_rows", default: 0
    t.integer "processed_rows", default: 0
    t.integer "error_rows", default: 0
    t.jsonb "errors_log", default: []
    t.datetime "finished_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["channel_id"], name: "index_imports_on_channel_id"
    t.index ["tenant_id"], name: "index_imports_on_tenant_id"
  end

  create_table "integration_events", force: :cascade do |t|
    t.bigint "tenant_id", null: false
    t.bigint "integration_id"
    t.string "provider", null: false
    t.string "event_type", null: false
    t.string "external_id"
    t.string "external_type"
    t.string "status", default: "pending", null: false
    t.jsonb "payload", default: {}, null: false
    t.jsonb "headers", default: {}, null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "received_at"
    t.datetime "processed_at"
    t.text "error_message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["integration_id", "external_id", "event_type"], name: "idx_integration_events_on_integration_external"
    t.index ["integration_id"], name: "index_integration_events_on_integration_id"
    t.index ["payload"], name: "index_integration_events_on_payload", using: :gin
    t.index ["received_at"], name: "index_integration_events_on_received_at"
    t.index ["tenant_id", "event_type"], name: "index_integration_events_on_tenant_id_and_event_type"
    t.index ["tenant_id", "provider"], name: "index_integration_events_on_tenant_id_and_provider"
    t.index ["tenant_id", "status"], name: "index_integration_events_on_tenant_id_and_status"
    t.index ["tenant_id"], name: "index_integration_events_on_tenant_id"
  end

  create_table "integration_mappings", force: :cascade do |t|
    t.bigint "tenant_id", null: false
    t.bigint "integration_id", null: false
    t.string "mappable_type"
    t.bigint "mappable_id"
    t.string "external_id", null: false
    t.string "external_code"
    t.string "external_type", null: false
    t.string "status", default: "active", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "last_synced_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["integration_id", "external_id", "external_type"], name: "idx_integration_mappings_on_integration_external", unique: true
    t.index ["integration_id"], name: "index_integration_mappings_on_integration_id"
    t.index ["mappable_type", "mappable_id"], name: "idx_integration_mappings_on_mappable"
    t.index ["metadata"], name: "index_integration_mappings_on_metadata", using: :gin
    t.index ["tenant_id", "external_type"], name: "index_integration_mappings_on_tenant_id_and_external_type"
    t.index ["tenant_id"], name: "index_integration_mappings_on_tenant_id"
  end

  create_table "integration_sync_logs", force: :cascade do |t|
    t.bigint "tenant_id", null: false
    t.bigint "integration_id"
    t.string "direction", null: false
    t.string "action", null: false
    t.string "status", null: false
    t.string "external_id"
    t.string "external_type"
    t.jsonb "request_payload", default: {}, null: false
    t.jsonb "response_payload", default: {}, null: false
    t.text "error_message"
    t.datetime "started_at"
    t.datetime "finished_at"
    t.integer "duration_ms"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["integration_id", "status"], name: "index_integration_sync_logs_on_integration_id_and_status"
    t.index ["integration_id"], name: "index_integration_sync_logs_on_integration_id"
    t.index ["metadata"], name: "index_integration_sync_logs_on_metadata", using: :gin
    t.index ["tenant_id", "created_at"], name: "index_integration_sync_logs_on_tenant_id_and_created_at"
    t.index ["tenant_id", "direction"], name: "index_integration_sync_logs_on_tenant_id_and_direction"
    t.index ["tenant_id", "status"], name: "index_integration_sync_logs_on_tenant_id_and_status"
    t.index ["tenant_id"], name: "index_integration_sync_logs_on_tenant_id"
  end

  create_table "integrations", force: :cascade do |t|
    t.bigint "tenant_id", null: false
    t.bigint "channel_id"
    t.string "provider", null: false
    t.string "name", null: false
    t.string "status", default: "disconnected", null: false
    t.jsonb "settings", default: {}, null: false
    t.jsonb "credentials", default: {}, null: false
    t.datetime "last_synced_at"
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["channel_id"], name: "index_integrations_on_channel_id"
    t.index ["settings"], name: "index_integrations_on_settings", using: :gin
    t.index ["tenant_id", "provider", "name"], name: "index_integrations_on_tenant_id_and_provider_and_name", unique: true
    t.index ["tenant_id", "provider"], name: "index_integrations_on_tenant_id_and_provider"
    t.index ["tenant_id", "status"], name: "index_integrations_on_tenant_id_and_status"
    t.index ["tenant_id"], name: "index_integrations_on_tenant_id"
  end

  create_table "kit_components", force: :cascade do |t|
    t.bigint "kit_product_id", null: false
    t.bigint "component_product_id", null: false
    t.decimal "quantity", precision: 10, scale: 3, default: "1.0", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["component_product_id"], name: "index_kit_components_on_component_product_id"
    t.index ["kit_product_id", "component_product_id"], name: "index_kit_components_on_kit_and_component", unique: true
    t.index ["kit_product_id"], name: "index_kit_components_on_kit_product_id"
  end

  create_table "lucrofrete_order_reports", force: :cascade do |t|
    t.bigint "tenant_id", null: false
    t.bigint "channel_id", null: false
    t.bigint "order_id"
    t.string "lucrofrete_order_id", null: false
    t.string "shopify_order_id"
    t.string "order_number", null: false
    t.datetime "order_created_at"
    t.string "customer_state"
    t.string "customer_city"
    t.string "customer_zipcode"
    t.decimal "total_order_value", precision: 12, scale: 2
    t.integer "total_items"
    t.decimal "freight_charged", precision: 12, scale: 2
    t.decimal "freight_cost", precision: 12, scale: 2
    t.decimal "margin_value", precision: 12, scale: 2
    t.decimal "margin_percent", precision: 10, scale: 2
    t.boolean "is_free_shipping"
    t.string "shipping_method_title"
    t.string "slot_name"
    t.string "carrier_name"
    t.string "match_status"
    t.string "quote_log_id"
    t.jsonb "raw_payload", default: {}, null: false
    t.datetime "synced_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["channel_id"], name: "index_lucrofrete_order_reports_on_channel_id"
    t.index ["order_id"], name: "index_lucrofrete_order_reports_on_order_id"
    t.index ["quote_log_id"], name: "index_lucrofrete_order_reports_on_quote_log_id"
    t.index ["tenant_id", "channel_id", "order_number"], name: "idx_lucrofrete_reports_tenant_channel_order"
    t.index ["tenant_id", "lucrofrete_order_id"], name: "idx_lucrofrete_reports_tenant_lf_id", unique: true
    t.index ["tenant_id", "match_status"], name: "idx_lucrofrete_reports_tenant_match_status"
    t.index ["tenant_id", "order_created_at"], name: "idx_lucrofrete_reports_tenant_created_at"
    t.index ["tenant_id"], name: "index_lucrofrete_order_reports_on_tenant_id"
  end

  create_table "order_items", force: :cascade do |t|
    t.bigint "order_id", null: false
    t.bigint "product_id"
    t.string "sku"
    t.string "name"
    t.integer "quantity", default: 1
    t.decimal "unit_price", precision: 10, scale: 2
    t.decimal "unit_cost", precision: 10, scale: 2
    t.decimal "discount", precision: 10, scale: 2, default: "0.0"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "is_gift", default: false, null: false
    t.decimal "nf_unit_price", precision: 10, scale: 2, default: "0.0", null: false
    t.index ["order_id"], name: "index_order_items_on_order_id"
    t.index ["product_id"], name: "index_order_items_on_product_id"
  end

  create_table "order_refunds", force: :cascade do |t|
    t.bigint "tenant_id", null: false
    t.bigint "order_id", null: false
    t.bigint "integration_id"
    t.string "external_id"
    t.decimal "amount", precision: 10, scale: 2, default: "0.0", null: false
    t.string "reason"
    t.string "status", default: "pending", null: false
    t.datetime "refunded_at"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["integration_id"], name: "index_order_refunds_on_integration_id"
    t.index ["order_id"], name: "index_order_refunds_on_order_id"
    t.index ["refunded_at"], name: "index_order_refunds_on_refunded_at"
    t.index ["status"], name: "index_order_refunds_on_status"
    t.index ["tenant_id", "external_id"], name: "index_order_refunds_on_tenant_id_and_external_id"
    t.index ["tenant_id"], name: "index_order_refunds_on_tenant_id"
  end

  create_table "orders", force: :cascade do |t|
    t.bigint "tenant_id", null: false
    t.bigint "channel_id", null: false
    t.string "external_id"
    t.string "order_number"
    t.decimal "gross_value", precision: 10, scale: 2, default: "0.0"
    t.decimal "cost_price", precision: 10, scale: 2, default: "0.0"
    t.decimal "freight", precision: 10, scale: 2, default: "0.0"
    t.decimal "discount", precision: 10, scale: 2, default: "0.0"
    t.decimal "commission", precision: 10, scale: 2, default: "0.0"
    t.decimal "operational_cost", precision: 10, scale: 2, default: "0.0"
    t.decimal "margin", precision: 10, scale: 2
    t.decimal "margin_pct", precision: 5, scale: 2
    t.string "status"
    t.string "payment_method"
    t.string "customer_name"
    t.string "customer_tag"
    t.string "state"
    t.decimal "weight_kg", precision: 8, scale: 3
    t.integer "items_qty", default: 1
    t.datetime "ordered_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "order_type", default: "sale", null: false
    t.decimal "refund_amount", precision: 10, scale: 2, default: "0.0", null: false
    t.string "nf_number"
    t.decimal "nf_gross_value", precision: 10, scale: 2, default: "0.0", null: false
    t.decimal "nf_discount", precision: 10, scale: 2, default: "0.0", null: false
    t.decimal "nf_freight", precision: 10, scale: 2, default: "0.0", null: false
    t.datetime "stock_deducted_at"
    t.decimal "real_freight_cost", precision: 10, scale: 2
    t.decimal "tax_amount", precision: 10, scale: 2
    t.string "coupon_code"
    t.decimal "coupon_discount", precision: 10, scale: 2, default: "0.0", null: false
    t.string "cart_token"
    t.string "shipping_service"
    t.decimal "original_shipping_fee", precision: 10, scale: 2
    t.decimal "shipping_fee_platform_discount", precision: 10, scale: 2
    t.decimal "shipping_fee_seller_discount", precision: 10, scale: 2
    t.index "tenant_id, lower((status)::text)", name: "index_orders_on_tenant_id_and_lower_status"
    t.index ["channel_id"], name: "index_orders_on_channel_id"
    t.index ["tenant_id", "cart_token"], name: "index_orders_on_tenant_id_and_cart_token"
    t.index ["tenant_id", "coupon_code"], name: "index_orders_on_tenant_id_and_coupon_code"
    t.index ["tenant_id", "external_id"], name: "index_orders_on_tenant_id_and_external_id"
    t.index ["tenant_id", "order_type"], name: "index_orders_on_tenant_id_and_order_type"
    t.index ["tenant_id", "ordered_at"], name: "index_orders_on_tenant_id_and_ordered_at"
    t.index ["tenant_id"], name: "index_orders_on_tenant_id"
  end

  create_table "payment_fee_rules", force: :cascade do |t|
    t.bigint "tenant_id", null: false
    t.string "payment_method", null: false
    t.string "card_brand"
    t.integer "installments_from", default: 1, null: false
    t.integer "installments_to", default: 1, null: false
    t.string "rate_type", null: false
    t.decimal "rate_value", precision: 8, scale: 4, null: false
    t.decimal "fixed_fee_boleto", precision: 10, scale: 2, default: "0.0"
    t.decimal "fixed_fee_gateway", precision: 10, scale: 2, default: "0.0"
    t.decimal "fixed_fee_antifraud", precision: 10, scale: 2, default: "0.0"
    t.decimal "withdrawal_fee", precision: 10, scale: 2, default: "0.0"
    t.decimal "anticipation_rate", precision: 8, scale: 4, default: "0.0"
    t.date "valid_from", null: false
    t.date "valid_until"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "payment_method", "card_brand"], name: "idx_payment_fee_rules_on_tenant_method_brand"
    t.index ["tenant_id", "valid_from"], name: "index_payment_fee_rules_on_tenant_id_and_valid_from"
    t.index ["tenant_id"], name: "index_payment_fee_rules_on_tenant_id"
  end

  create_table "pricing_rules", force: :cascade do |t|
    t.bigint "product_id", null: false
    t.bigint "channel_id", null: false
    t.decimal "target_margin_pct", precision: 5, scale: 2, default: "30.0"
    t.decimal "suggested_price", precision: 10, scale: 2
    t.decimal "current_price", precision: 10, scale: 2
    t.datetime "last_calculated_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["channel_id"], name: "index_pricing_rules_on_channel_id"
    t.index ["product_id", "channel_id"], name: "index_pricing_rules_on_product_id_and_channel_id", unique: true
    t.index ["product_id"], name: "index_pricing_rules_on_product_id"
  end

  create_table "products", force: :cascade do |t|
    t.bigint "tenant_id", null: false
    t.string "sku", null: false
    t.string "name", null: false
    t.decimal "cost_price", precision: 10, scale: 2, default: "0.0"
    t.string "idworks_id"
    t.boolean "active", default: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "is_kit", default: false, null: false
    t.decimal "tax_rate", precision: 5, scale: 2
    t.index ["tenant_id", "sku"], name: "index_products_on_tenant_id_and_sku", unique: true
    t.index ["tenant_id"], name: "index_products_on_tenant_id"
  end

  create_table "tenants", force: :cascade do |t|
    t.string "name", null: false
    t.string "slug", null: false
    t.string "plan", default: "starter"
    t.boolean "active", default: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "tv_token"
    t.index ["slug"], name: "index_tenants_on_slug", unique: true
    t.index ["tv_token"], name: "index_tenants_on_tv_token", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.bigint "tenant_id", null: false
    t.string "name", null: false
    t.string "email", null: false
    t.string "password_digest", null: false
    t.string "role", default: "operador", null: false
    t.boolean "active", default: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "email"], name: "index_users_on_tenant_id_and_email", unique: true
    t.index ["tenant_id"], name: "index_users_on_tenant_id"
  end

  add_foreign_key "audit_conflicts", "orders"
  add_foreign_key "audit_conflicts", "products"
  add_foreign_key "audit_conflicts", "tenants"
  add_foreign_key "audit_conflicts", "users", column: "resolved_by_id"
  add_foreign_key "carts", "channels"
  add_foreign_key "carts", "orders", column: "converted_order_id"
  add_foreign_key "carts", "tenants"
  add_foreign_key "channel_credentials", "channel_credentials", column: "stock_source_channel_id"
  add_foreign_key "channel_credentials", "tenants"
  add_foreign_key "channel_operational_costs", "channels"
  add_foreign_key "channel_operational_costs", "products"
  add_foreign_key "channel_product_listings", "products"
  add_foreign_key "channel_product_listings", "tenants"
  add_foreign_key "channels", "tenants"
  add_foreign_key "data_source_configs", "tenants"
  add_foreign_key "financial_receivables", "financial_settlement_items"
  add_foreign_key "financial_receivables", "financial_sources"
  add_foreign_key "financial_receivables", "orders"
  add_foreign_key "financial_receivables", "tenants"
  add_foreign_key "financial_settlement_items", "financial_settlements"
  add_foreign_key "financial_settlement_items", "orders"
  add_foreign_key "financial_settlement_items", "tenants"
  add_foreign_key "financial_settlements", "channels"
  add_foreign_key "financial_settlements", "financial_sources"
  add_foreign_key "financial_settlements", "integrations"
  add_foreign_key "financial_settlements", "tenants"
  add_foreign_key "financial_sources", "channels"
  add_foreign_key "financial_sources", "integrations"
  add_foreign_key "financial_sources", "tenants"
  add_foreign_key "freight_margin_dailies", "channels"
  add_foreign_key "freight_margin_dailies", "tenants"
  add_foreign_key "freight_quotes", "channels"
  add_foreign_key "freight_quotes", "tenants"
  add_foreign_key "imports", "channels"
  add_foreign_key "imports", "tenants"
  add_foreign_key "integration_events", "integrations"
  add_foreign_key "integration_events", "tenants"
  add_foreign_key "integration_mappings", "integrations"
  add_foreign_key "integration_mappings", "tenants"
  add_foreign_key "integration_sync_logs", "integrations"
  add_foreign_key "integration_sync_logs", "tenants"
  add_foreign_key "integrations", "channels"
  add_foreign_key "integrations", "tenants"
  add_foreign_key "kit_components", "products", column: "component_product_id"
  add_foreign_key "kit_components", "products", column: "kit_product_id"
  add_foreign_key "lucrofrete_order_reports", "channels"
  add_foreign_key "lucrofrete_order_reports", "orders"
  add_foreign_key "lucrofrete_order_reports", "tenants"
  add_foreign_key "order_items", "orders"
  add_foreign_key "order_items", "products"
  add_foreign_key "order_refunds", "integrations"
  add_foreign_key "order_refunds", "orders"
  add_foreign_key "order_refunds", "tenants"
  add_foreign_key "orders", "channels"
  add_foreign_key "orders", "tenants"
  add_foreign_key "payment_fee_rules", "tenants"
  add_foreign_key "pricing_rules", "channels"
  add_foreign_key "pricing_rules", "products"
  add_foreign_key "products", "tenants"
  add_foreign_key "users", "tenants"
end
