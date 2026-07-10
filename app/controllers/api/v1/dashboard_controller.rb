module Api
  module V1
    class DashboardController < ApplicationController
      def summary
        render json: Dashboard::BuildSummary.call(tenant: current_tenant, params: params)
      end

      def financial
        settlements = apply_financial_filters(current_tenant.financial_settlements)
        items       = FinancialSettlementItem.where(
          tenant: current_tenant,
          financial_settlement_id: settlements.select(:id)
        )

        render json: {
          totals:          build_financial_totals(settlements, items),
          by_source:       build_financial_by_source(items),
          by_status:       build_financial_by_status(settlements),
          disputed_items:  build_disputed_items(items),
          unmatched_items: build_unmatched_items(items)
        }
      end

      private

      def apply_financial_filters(scope)
        scope = scope.where(financial_source_id: params[:financial_source_id]) if params[:financial_source_id].present?
        scope = scope.where(channel_id:          params[:channel_id])          if params[:channel_id].present?
        scope = scope.where(status:               params[:status])             if params[:status].present?

        scope = scope.where("period_start >= ?", params[:date_from]) if params[:date_from].present?
        scope = scope.where("period_start <= ?", params[:date_to])   if params[:date_to].present?

        scope = scope.where("expected_payout_date >= ?", params[:payout_from]) if params[:payout_from].present?
        scope = scope.where("expected_payout_date <= ?", params[:payout_to])   if params[:payout_to].present?

        scope
      end

      def build_financial_totals(settlements, items)
        agg = items.pick(
          Arel.sql("COALESCE(SUM(gross_amount), 0)"),
          Arel.sql("COALESCE(SUM(fee_amount), 0)"),
          Arel.sql("COALESCE(SUM(discount_amount), 0)"),
          Arel.sql("COALESCE(SUM(refund_amount), 0)"),
          Arel.sql("COALESCE(SUM(chargeback_amount), 0)"),
          Arel.sql("COALESCE(SUM(net_amount), 0)"),
          Arel.sql("COALESCE(SUM(expected_amount), 0)"),
          Arel.sql("COALESCE(SUM(difference_amount), 0)")
        ) || Array.new(8, 0)

        gross, fee, discount, refund, chargeback, net, expected, difference = agg
        status_counts = items.group(:status).count

        {
          settlements_count:  settlements.count,
          items_count:        items.count,
          gross_amount:       gross.to_f.round(2),
          fee_amount:         fee.to_f.round(2),
          discount_amount:    discount.to_f.round(2),
          refund_amount:      refund.to_f.round(2),
          chargeback_amount:  chargeback.to_f.round(2),
          net_amount:         net.to_f.round(2),
          expected_amount:    expected.to_f.round(2),
          difference_amount:  difference.to_f.round(2),
          matched_count:      status_counts["matched"]   || 0,
          unmatched_count:    status_counts["unmatched"] || 0,
          disputed_count:     status_counts["disputed"]  || 0
        }
      end

      def build_financial_by_source(items)
        rows = items
          .joins(financial_settlement: :financial_source)
          .group(
            Arel.sql("financial_sources.id"),
            Arel.sql("financial_sources.name"),
            Arel.sql("financial_sources.provider"),
            Arel.sql("financial_sources.source_type")
          )
          .pluck(
            Arel.sql("financial_sources.id"),
            Arel.sql("financial_sources.name"),
            Arel.sql("financial_sources.provider"),
            Arel.sql("financial_sources.source_type"),
            Arel.sql("COUNT(DISTINCT financial_settlement_items.financial_settlement_id)"),
            Arel.sql("COUNT(financial_settlement_items.id)"),
            Arel.sql("COALESCE(SUM(financial_settlement_items.gross_amount), 0)"),
            Arel.sql("COALESCE(SUM(financial_settlement_items.net_amount), 0)"),
            Arel.sql("COALESCE(SUM(financial_settlement_items.expected_amount), 0)"),
            Arel.sql("COALESCE(SUM(financial_settlement_items.difference_amount), 0)"),
            Arel.sql("COUNT(*) FILTER (WHERE financial_settlement_items.status = 'matched')"),
            Arel.sql("COUNT(*) FILTER (WHERE financial_settlement_items.status = 'unmatched')"),
            Arel.sql("COUNT(*) FILTER (WHERE financial_settlement_items.status = 'disputed')")
          )

        rows.map do |id, name, provider, source_type, settlements_count, items_count, gross, net, expected, difference, matched, unmatched, disputed|
          {
            financial_source_id:   id,
            financial_source_name: name,
            provider:              provider,
            source_type:           source_type,
            settlements_count:     settlements_count.to_i,
            items_count:           items_count.to_i,
            gross_amount:          gross.to_f.round(2),
            net_amount:            net.to_f.round(2),
            expected_amount:       expected.to_f.round(2),
            difference_amount:     difference.to_f.round(2),
            matched_count:         matched.to_i,
            unmatched_count:       unmatched.to_i,
            disputed_count:        disputed.to_i
          }
        end
      end

      def build_financial_by_status(settlements)
        rows = settlements
          .group(:status)
          .pluck(
            :status,
            Arel.sql("COUNT(*)"),
            Arel.sql("COALESCE(SUM(gross_amount), 0)"),
            Arel.sql("COALESCE(SUM(net_amount), 0)")
          )

        rows.map do |status, count, gross, net|
          {
            status:            status,
            settlements_count: count.to_i,
            gross_amount:      gross.to_f.round(2),
            net_amount:        net.to_f.round(2)
          }
        end
      end

      def build_disputed_items(items)
        items
          .where(status: "disputed")
          .includes(:order, financial_settlement: :financial_source)
          .order(created_at: :desc)
          .limit(10)
          .map { |i| disputed_item_json(i) }
      end

      def build_unmatched_items(items)
        items
          .where(status: "unmatched")
          .includes(financial_settlement: :financial_source)
          .order(created_at: :desc)
          .limit(10)
          .map { |i| unmatched_item_json(i) }
      end

      def disputed_item_json(item)
        {
          id:                      item.id,
          financial_settlement_id: item.financial_settlement_id,
          financial_source_name:   item.financial_settlement&.financial_source&.name,
          external_order_id:       item.external_order_id,
          order_id:                item.order_id,
          order_number:            item.order&.order_number,
          net_amount:              item.net_amount,
          expected_amount:         item.expected_amount,
          difference_amount:       item.difference_amount,
          transaction_date:        item.transaction_date,
          payout_date:             item.payout_date
        }
      end

      def unmatched_item_json(item)
        {
          id:                      item.id,
          financial_settlement_id: item.financial_settlement_id,
          financial_source_name:   item.financial_settlement&.financial_source&.name,
          external_order_id:       item.external_order_id,
          net_amount:              item.net_amount,
          transaction_date:        item.transaction_date,
          payout_date:             item.payout_date
        }
      end

    end
  end
end
