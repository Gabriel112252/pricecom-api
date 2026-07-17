module Integrations
  module Tiktok
    # Rebuilds the dashboard freight-margin daily row for TikTok orders from
    # local order data only. TikTok uses platform logistics, so "Custo real"
    # here is Order#original_shipping_fee (payment.original_shipping_fee from
    # TikTok Shop), not Order#real_freight_cost / Melhor Envio / LucroFrete.
    class FreightMarginDailySyncService
      def self.call(order, dates: nil)
        new(order, dates: dates).call
      end

      def initialize(order, dates: nil)
        @order = order
        @tenant = order.tenant
        @channel = order.channel
        @dates = normalize_dates(Array(dates) + [ order.ordered_at ])
      end

      def call
        return unless channel&.platform == "tiktok"
        return unless freight_margin_available?

        dates.each { |date| rebuild_day(date) }
      end

      private

      attr_reader :order, :tenant, :channel, :dates

      def rebuild_day(date)
        row = tenant.freight_margin_dailies.find_or_initialize_by(channel: channel, date: date)
        scope = orders_for(date)
        order_count = scope.count

        return if order_count.zero? && row.new_record?

        charged = money(scope.sum(:freight))
        cost = money(scope.sum(:original_shipping_fee))
        margin = charged - cost

        row.assign_attributes(
          order_count: order_count,
          freight_charged: charged.round(2),
          freight_cost: cost.round(2),
          margin_value: margin.round(2),
          margin_percent: charged.positive? ? (margin / charged * 100).round(2) : nil,
          free_shipping_count: order_count.positive? ? scope.where(freight: 0).count : 0,
          synced_at: Time.current
        )
        row.save!
      end

      def orders_for(date)
        tenant.orders
          .where(channel: channel, ordered_at: day_range(date))
          .sales
          .revenue_countable
          .where.not(original_shipping_fee: nil)
      end

      def day_range(date)
        date.in_time_zone.all_day
      end

      def normalize_dates(values)
        values.filter_map { |value| normalize_date(value) }.uniq
      end

      def normalize_date(value)
        return value if value.is_a?(Date)
        return value.in_time_zone.to_date if value.respond_to?(:in_time_zone)

        nil
      end

      def money(value)
        BigDecimal(value.to_s)
      end

      def freight_margin_available?
        return @freight_margin_available if defined?(@freight_margin_available)

        @freight_margin_available = FreightMarginDaily.table_exists?
      rescue StandardError
        @freight_margin_available = false
      end
    end
  end
end
