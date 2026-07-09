module Financials
  class MatchSettlementItem
    CONFLICT_TYPE  = "settlement_amount_mismatch"
    MATCH_TOLERANCE = 0.01

    Result = Struct.new(:ok, :skipped, :item, :error_message, keyword_init: true) do
      def success? = ok
      def skipped? = skipped
    end

    def self.call(item)
      new(item).call
    end

    def initialize(item)
      @item   = item
      @tenant = item.tenant
    end

    def call
      ActiveRecord::Base.transaction do
        order = find_order
        return handle_unmatched unless order

        match_item(order)
      end
    rescue => e
      Result.new(ok: false, skipped: false, item: item, error_message: e.message)
    end

    private

    attr_reader :item, :tenant

    def find_order
      return nil if item.external_order_id.blank?

      tenant.orders.find_by(external_id: item.external_order_id) ||
        tenant.orders.find_by(order_number: item.external_order_id)
    end

    def handle_unmatched
      item.assign_attributes(
        status: "unmatched",
        expected_amount: 0,
        difference_amount: item.net_amount.to_f
      )
      item.save!

      Result.new(
        ok: true,
        skipped: true,
        item: item,
        error_message: "Pedido não encontrado para external_order_id=#{item.external_order_id.inspect}"
      )
    end

    def match_item(order)
      expected_amount = expected_amount_for(order)
      difference      = (item.net_amount.to_f - expected_amount).round(2)
      status          = difference.abs <= MATCH_TOLERANCE ? "matched" : "disputed"

      item.assign_attributes(
        order:              order,
        expected_amount:    expected_amount,
        difference_amount:  difference,
        status:             status
      )
      item.save!

      if status == "disputed"
        upsert_conflict(order, expected_amount, difference)
      else
        resolve_conflict(order)
      end

      Result.new(ok: true, skipped: false, item: item, error_message: nil)
    end

    def expected_amount_for(order)
      if order.respond_to?(:net_gross_value)
        order.net_gross_value.to_f
      else
        order.gross_value.to_f - order.refund_amount.to_f
      end
    end

    def find_open_conflict(order)
      AuditConflict
        .where(tenant: tenant, order: order, conflict_type: CONFLICT_TYPE, status: "open")
        .where("metadata ->> 'financial_settlement_item_id' = ?", item.id.to_s)
        .first
    end

    def upsert_conflict(order, expected_amount, difference)
      conflict = find_open_conflict(order) || AuditConflict.new(
        tenant: tenant,
        order: order,
        conflict_type: CONFLICT_TYPE,
        status: "open"
      )

      conflict.assign_attributes(
        severity:       "high",
        status:         "open",
        source:         "auto",
        expected_value: expected_amount,
        actual_value:   item.net_amount,
        difference:     difference,
        metadata: {
          "financial_settlement_item_id" => item.id,
          "financial_settlement_id"      => item.financial_settlement_id,
          "financial_source_id"          => item.financial_settlement.financial_source_id,
          "external_order_id"            => item.external_order_id
        }
      )
      conflict.save!
    end

    def resolve_conflict(order)
      conflict = find_open_conflict(order)
      return unless conflict

      conflict.update!(status: "resolved", resolved_at: Time.current)
    end
  end
end
