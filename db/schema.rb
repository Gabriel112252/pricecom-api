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

ActiveRecord::Schema[7.2].define(version: 2026_07_09_200003) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

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
    t.index ["channel_id"], name: "index_orders_on_channel_id"
    t.index ["tenant_id", "external_id"], name: "index_orders_on_tenant_id_and_external_id"
    t.index ["tenant_id", "order_type"], name: "index_orders_on_tenant_id_and_order_type"
    t.index ["tenant_id", "ordered_at"], name: "index_orders_on_tenant_id_and_ordered_at"
    t.index ["tenant_id"], name: "index_orders_on_tenant_id"
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
    t.index ["slug"], name: "index_tenants_on_slug", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.bigint "tenant_id", null: false
    t.string "name", null: false
    t.string "email", null: false
    t.string "password_digest", null: false
    t.string "role", default: "member"
    t.boolean "active", default: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "email"], name: "index_users_on_tenant_id_and_email", unique: true
    t.index ["tenant_id"], name: "index_users_on_tenant_id"
  end

  add_foreign_key "channel_operational_costs", "channels"
  add_foreign_key "channel_operational_costs", "products"
  add_foreign_key "channels", "tenants"
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
  add_foreign_key "order_items", "orders"
  add_foreign_key "order_items", "products"
  add_foreign_key "order_refunds", "integrations"
  add_foreign_key "order_refunds", "orders"
  add_foreign_key "order_refunds", "tenants"
  add_foreign_key "orders", "channels"
  add_foreign_key "orders", "tenants"
  add_foreign_key "pricing_rules", "channels"
  add_foreign_key "pricing_rules", "products"
  add_foreign_key "products", "tenants"
  add_foreign_key "users", "tenants"
end
