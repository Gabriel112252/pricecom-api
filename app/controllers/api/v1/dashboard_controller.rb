module Api
  module V1
    class DashboardController < ApplicationController
      def summary
        base = apply_filters(current_tenant.orders.includes(:channel))

        render json: {
          totals:            build_totals(base),
          by_channel:        build_by_channel(base),
          by_status:         build_by_status(base),
          low_margin_orders: build_low_margin(base),
          recent_orders:     build_recent(base)
        }
      end

      private

      def apply_filters(scope)
        scope = scope.where(channel_id: params[:channel_id]) if params[:channel_id].present?
        scope = scope.where(status:     params[:status])     if params[:status].present?
        scope = scope.where("ordered_at >= ?", params[:date_from]) if params[:date_from].present?
        scope = scope.where("ordered_at <= ?", params[:date_to])   if params[:date_to].present?
        scope
      end

      def build_totals(scope)
        agg = scope.pick(
          Arel.sql("COUNT(*)"),
          Arel.sql("COALESCE(SUM(gross_value), 0)"),
          Arel.sql("COALESCE(SUM(cost_price), 0)"),
          Arel.sql("COALESCE(SUM(freight), 0)"),
          Arel.sql("COALESCE(SUM(discount), 0)"),
          Arel.sql("COALESCE(SUM(commission), 0)"),
          Arel.sql("COALESCE(SUM(operational_cost), 0)"),
          Arel.sql("COALESCE(SUM(margin), 0)")
        )

        orders_count, gross, cost, freight, discount, commission, op_cost, margin = agg

        margin_pct = gross.to_f > 0 ? (margin.to_f / gross.to_f * 100).round(2) : 0

        {
          orders_count:     orders_count,
          gross_value:      gross.to_f.round(2),
          cost_price:       cost.to_f.round(2),
          freight:          freight.to_f.round(2),
          discount:         discount.to_f.round(2),
          commission:       commission.to_f.round(2),
          operational_cost: op_cost.to_f.round(2),
          margin:           margin.to_f.round(2),
          margin_pct:       margin_pct
        }
      end

      def build_by_channel(scope)
        rows = scope
          .joins(:channel)
          .group(Arel.sql("channels.id"), Arel.sql("channels.name"))
          .pluck(
            Arel.sql("channels.id"),
            Arel.sql("channels.name"),
            Arel.sql("COUNT(orders.id)"),
            Arel.sql("COALESCE(SUM(orders.gross_value), 0)"),
            Arel.sql("COALESCE(SUM(orders.margin), 0)")
          )

        rows.map do |channel_id, channel_name, count, gross, margin|
          margin_pct = gross.to_f > 0 ? (margin.to_f / gross.to_f * 100).round(2) : 0
          {
            channel_id:   channel_id,
            channel_name: channel_name,
            orders_count: count,
            gross_value:  gross.to_f.round(2),
            margin:       margin.to_f.round(2),
            margin_pct:   margin_pct
          }
        end
      end

      def build_by_status(scope)
        rows = scope
          .group(:status)
          .pluck(
            :status,
            Arel.sql("COUNT(*)"),
            Arel.sql("COALESCE(SUM(gross_value), 0)"),
            Arel.sql("COALESCE(SUM(margin), 0)")
          )

        rows.map do |status, count, gross, margin|
          {
            status:       status,
            orders_count: count,
            gross_value:  gross.to_f.round(2),
            margin:       margin.to_f.round(2)
          }
        end
      end

      def build_low_margin(scope)
        scope
          .order(margin_pct: :asc)
          .limit(10)
          .map { |o| order_summary_json(o) }
      end

      def build_recent(scope)
        scope
          .order(ordered_at: :desc, created_at: :desc)
          .limit(10)
          .map { |o| order_summary_json(o, with_status: true) }
      end

      def order_summary_json(order, with_status: false)
        result = {
          id:            order.id,
          channel_name:  order.channel&.name,
          order_number:  order.order_number,
          customer_name: order.customer_name,
          gross_value:   order.gross_value.to_f.round(2),
          margin:        order.margin.to_f.round(2),
          margin_pct:    order.margin_pct.to_f,
          ordered_at:    order.ordered_at
        }
        result[:status] = order.status if with_status
        result
      end
    end
  end
end
