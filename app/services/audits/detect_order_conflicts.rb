module Audits
  class DetectOrderConflicts
    CANCEL_LIKE_STATUSES = %w[refunded canceled cancelled].freeze

    def self.call(order)
      new(order).call
    end

    def initialize(order)
      @order  = order
      @tenant = order.tenant
    end

    def call
      ActiveRecord::Base.transaction do
        detect_missing_cost
        detect_gift_costing_error
        detect_nf_discount_mismatch
        detect_nf_freight_mismatch
        detect_refund_without_cancellation
      end
    end

    private

    attr_reader :order, :tenant

    def detect_missing_cost
      triggered_product_ids = []

      order.order_items.non_gifts.includes(:product).find_each do |item|
        product = item.product
        next unless cost_missing?(item.unit_cost) && cost_missing?(product&.cost_price)

        triggered_product_ids << product&.id
        upsert_conflict(
          conflict_type: "missing_cost",
          product: product,
          severity: "high",
          expected_value: 0,
          actual_value: 0,
          difference: 0,
          metadata: {
            sku: item.sku,
            item_name: item.name,
            unit_cost: item.unit_cost.to_f,
            product_cost_price: product&.cost_price.to_f
          }
        )
      end

      resolve_stale(conflict_type: "missing_cost", keep_product_ids: triggered_product_ids)
    end

    def detect_gift_costing_error
      triggered_product_ids = []

      order.order_items.gifts.includes(:product).find_each do |item|
        next unless item.unit_cost.present? && item.unit_cost > 0

        product = item.product
        triggered_product_ids << product&.id
        upsert_conflict(
          conflict_type: "gift_costing_error",
          product: product,
          severity: "medium",
          expected_value: 0,
          actual_value: item.unit_cost,
          difference: item.unit_cost,
          metadata: {
            sku: item.sku,
            item_name: item.name,
            unit_cost: item.unit_cost.to_f
          }
        )
      end

      resolve_stale(conflict_type: "gift_costing_error", keep_product_ids: triggered_product_ids)
    end

    def detect_nf_discount_mismatch
      discount    = order.discount.to_f
      nf_discount = order.nf_discount.to_f
      difference  = (nf_discount - discount).round(2)

      if nf_discount > 0 && difference.abs > 0.01
        upsert_conflict(
          conflict_type: "nf_discount_mismatch",
          severity: "high",
          expected_value: discount,
          actual_value: nf_discount,
          difference: difference,
          metadata: { nf_number: order.nf_number }
        )
      else
        resolve_stale(conflict_type: "nf_discount_mismatch", keep_product_ids: [])
      end
    end

    def detect_nf_freight_mismatch
      freight    = order.freight.to_f
      nf_freight = order.nf_freight.to_f
      difference = (nf_freight - freight).round(2)

      if nf_freight > 0 && difference.abs > 0.01
        upsert_conflict(
          conflict_type: "nf_freight_mismatch",
          severity: "medium",
          expected_value: freight,
          actual_value: nf_freight,
          difference: difference,
          metadata: { nf_number: order.nf_number }
        )
      else
        resolve_stale(conflict_type: "nf_freight_mismatch", keep_product_ids: [])
      end
    end

    def detect_refund_without_cancellation
      refund_amount = order.refund_amount.to_f
      cancel_like   = CANCEL_LIKE_STATUSES.include?(order.status.to_s.downcase)

      if refund_amount > 0 && !cancel_like
        upsert_conflict(
          conflict_type: "refund_without_cancellation",
          severity: "medium",
          expected_value: 0,
          actual_value: refund_amount,
          difference: refund_amount,
          metadata: { order_status: order.status }
        )
      else
        resolve_stale(conflict_type: "refund_without_cancellation", keep_product_ids: [])
      end
    end

    def cost_missing?(value)
      value.nil? || value.zero?
    end

    def upsert_conflict(conflict_type:, severity:, expected_value:, actual_value:, difference:, metadata:, product: nil)
      conflict = AuditConflict.find_or_initialize_by(
        tenant: tenant,
        order: order,
        product: product,
        conflict_type: conflict_type,
        status: "open"
      )

      conflict.assign_attributes(
        severity: severity,
        expected_value: expected_value,
        actual_value: actual_value,
        difference: difference,
        source: "auto",
        metadata: metadata
      )
      conflict.save!
    end

    def resolve_stale(conflict_type:, keep_product_ids:)
      order.audit_conflicts.where(conflict_type: conflict_type, status: "open").find_each do |conflict|
        next if keep_product_ids.include?(conflict.product_id)

        conflict.update!(status: "resolved", resolved_at: Time.current)
      end
    end
  end
end
