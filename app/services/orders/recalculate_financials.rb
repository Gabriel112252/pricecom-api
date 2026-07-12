module Orders
  class RecalculateFinancials
    Result = Struct.new(:order, :missing_cost_items_count, keyword_init: true)

    def self.call(order, run_audit: true)
      new(order, run_audit: run_audit).call
    end

    def initialize(order, run_audit: true)
      @order = order
      @run_audit = run_audit
    end

    def call
      items = order.order_items.reload
      non_gifts = items.reject(&:is_gift)

      order.assign_attributes(
        cost_price: cost_price_for(non_gifts),
        commission: commission_for,
        operational_cost: operational_cost_for(non_gifts)
      )
      order.save!

      Audits::DetectOrderConflicts.call(order) if run_audit

      Result.new(
        order: order,
        missing_cost_items_count: non_gifts.count { |item| cost_missing?(item.unit_cost) }
      )
    end

    private

    attr_reader :order, :run_audit

    def cost_price_for(items)
      items.sum { |item| item.quantity.to_i * item.unit_cost.to_f }
    end

    def commission_for
      channel = order.channel
      return 0 unless channel

      commission_pct = channel.commission_pct.to_f / 100.0
      ((order.gross_value.to_f * commission_pct) + channel.commission_fixed.to_f).round(2)
    end

    def operational_cost_for(items)
      channel = order.channel
      return 0 unless channel

      items.sum do |item|
        next 0 unless item.product_id

        ChannelOperationalCost.find_by(product_id: item.product_id, channel: channel)&.cost.to_f
      end
    end

    def cost_missing?(value)
      value.nil? || value.zero?
    end
  end
end
