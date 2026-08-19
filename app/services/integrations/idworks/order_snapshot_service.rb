module Integrations
  module Idworks
    # Persists the ERP's order view independently from Pricecom::Order.
    # An IDWorks order is useful for the comparison dashboard even when no
    # marketplace order was imported into Pricecom or no mapping exists.
    class OrderSnapshotService
      def self.persist!(integration, raw_orders, seen_at: Time.current)
        new(integration, raw_orders, seen_at: seen_at).persist!
      end

      def initialize(integration, raw_orders, seen_at:)
        @integration = integration
        @raw_orders = raw_orders
        @seen_at = seen_at
      end

      def persist!
        rows_by_external_id = @raw_orders.each_with_object({}) do |raw_order, rows|
          external_id = raw_order[:idworks_order_id].to_s.strip.presence
          next unless external_id

          rows[external_id] = {
            tenant_id: @integration.tenant_id,
            integration_id: @integration.id,
            external_id: external_id,
            order_number: raw_order[:order_ref].presence,
            recorded_at: raw_order[:recorded_at],
            status_order: raw_order[:status_order].presence,
            id_status_order: raw_order[:id_status_order],
            sales_channel_slug: raw_order[:sales_channel_slug].presence,
            value_shipping: raw_order[:value_shipping],
            value_product: raw_order[:value_product],
            value_order: raw_order[:value_order],
            value_paid: raw_order[:value_paid],
            last_seen_at: @seen_at,
            created_at: @seen_at,
            updated_at: @seen_at
          }
        end

        rows = rows_by_external_id.values
        return 0 if rows.empty?

        IdworksOrder.upsert_all(rows, unique_by: "idx_idworks_orders_on_integration_external")
        rows.size
      end
    end
  end
end
