module Api
  module V1
    class DashboardController < ApplicationController
      RECEIVABLE_SORTS = {
        "payment_date" => "financial_receivables.payment_date",
        "status" => "financial_receivables.status",
        "payment_method" => "financial_receivables.payment_method",
        "amount" => "financial_receivables.amount",
        "fee_amount" => "financial_receivables.fee_amount",
        "net_amount" => "financial_receivables.net_amount"
      }.freeze

      PER_PAGE_DEFAULT = 25
      PER_PAGE_MAX = 100

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
          unmatched_items: build_unmatched_items(items),
          receivables_dashboard: build_receivables_dashboard(apply_receivable_filters(current_tenant.financial_receivables))
        }
      end

      private

      def apply_financial_filters(scope)
        reconciliation_source = DataSourceConfig.source_for(current_tenant, "payment_reconciliation")
        scope = scope.joins(:financial_source).where(financial_sources: { provider: reconciliation_source }) if reconciliation_source.present?

        if params[:financial_source_id].present? && params[:financial_source_id] != "all"
          scope = scope.where(financial_source_id: params[:financial_source_id])
        end
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

      def apply_receivable_filters(scope)
        scope = scope.includes(:order, :financial_source)
          .joins(:financial_source)
          .where(financial_sources: { provider: "pagarme" })

        if params[:financial_source_id].present? && params[:financial_source_id] != "all"
          scope = scope.where(financial_source_id: params[:financial_source_id])
        end
        scope = scope.where(status: params[:receivable_status]) if params[:receivable_status].present?
        scope = scope.where(payment_method: params[:payment_method]) if params[:payment_method].present?
        scope = scope.where("financial_receivables.payment_date >= ?", params[:payment_date_from]) if params[:payment_date_from].present?
        scope = scope.where("financial_receivables.payment_date <= ?", params[:payment_date_to]) if params[:payment_date_to].present?

        scope
      end

      def build_receivables_dashboard(receivables)
        {
          gateway_options: build_receivable_gateway_options,
          cash_flow: build_receivable_cash_flow(receivables),
          by_payment_method: build_receivable_by_payment_method(receivables),
          fee_summary: build_receivable_fee_summary(receivables),
          status_options: receivables.reorder(nil).distinct.pluck(Arel.sql("financial_receivables.status")).compact.sort,
          payment_method_options: receivables.reorder(nil).distinct.pluck(Arel.sql("financial_receivables.payment_method")).compact.sort,
          table: build_receivable_table(receivables)
        }
      end

      def build_receivable_gateway_options
        enabled = current_tenant.financial_sources
          .gateways
          .active
          .where.not(provider: "tiktok")
          .order(:name)
          .map do |source|
            {
              financial_source_id: source.id,
              provider: source.provider,
              label: receivable_gateway_label(source),
              disabled: false,
              reason: nil
            }
          end

        enabled + [
          {
            financial_source_id: nil,
            provider: "tiktok",
            label: "TikTok Shop",
            disabled: true,
            reason: "TikTok Shop tem liquidação direta pelo marketplace, sem recebíveis de gateway disponíveis."
          }
        ]
      end

      def receivable_gateway_label(source)
        return "#{source.channel&.name || 'Yampi'} (via Pagar.me)" if source.provider == "pagarme"

        source.name
      end

      def build_receivable_cash_flow(receivables)
        date_from = parse_date_param(params[:payment_date_from]) || Date.current
        date_to = parse_date_param(params[:payment_date_to]) || 30.days.from_now.to_date
        scoped = receivables.where(payment_date: date_from..date_to)
        grouped = scoped.group(:payment_date, :status).sum(:net_amount)

        timeline = (date_from..date_to).map do |date|
          paid = grouped[[ date, "paid" ]].to_f
          waiting = grouped.select { |(payment_date, status), _| payment_date == date && status != "paid" }.values.sum(&:to_f)

          {
            date: date.iso8601,
            paid_amount: paid.round(2),
            waiting_funds_amount: waiting.round(2),
            total_amount: (paid + waiting).round(2)
          }
        end

        {
          timeline: timeline,
          windows: [
            receivable_cash_window("Hoje", Date.current, Date.current, receivables),
            receivable_cash_window("Próximos 7 dias", Date.current, 7.days.from_now.to_date, receivables),
            receivable_cash_window("Próximos 30 dias", Date.current, 30.days.from_now.to_date, receivables)
          ]
        }
      end

      def receivable_cash_window(label, from, to, receivables)
        scoped = receivables.where(payment_date: from..to)
        paid = scoped.where(status: "paid").sum(:net_amount).to_f
        waiting = scoped.where.not(status: "paid").sum(:net_amount).to_f

        {
          label: label,
          paid_amount: paid.round(2),
          waiting_funds_amount: waiting.round(2),
          total_amount: (paid + waiting).round(2)
        }
      end

      def build_receivable_by_payment_method(receivables)
        rows = receivables
          .group(:payment_method)
          .pluck(
            :payment_method,
            Arel.sql("COUNT(*)"),
            Arel.sql("COALESCE(SUM(amount), 0)"),
            Arel.sql("COALESCE(SUM(net_amount), 0)"),
            Arel.sql("COUNT(*) FILTER (WHERE financial_receivables.status != 'paid')")
          )

        rows.map do |method, count, amount, net, pending|
          {
            payment_method: method.presence || "unknown",
            receivables_count: count.to_i,
            gross_amount: amount.to_f.round(2),
            net_amount: net.to_f.round(2),
            pending_installments_count: pending.to_i
          }
        end
      end

      def build_receivable_fee_summary(receivables)
        fee, anticipation_fee, total, count = receivables.pick(
          Arel.sql("COALESCE(SUM(fee_amount), 0)"),
          Arel.sql("COALESCE(SUM(anticipation_fee_amount), 0)"),
          Arel.sql("COALESCE(SUM(fee_amount + anticipation_fee_amount), 0)"),
          Arel.sql("COUNT(*)")
        ) || [ 0, 0, 0, 0 ]

        {
          receivables_count: count.to_i,
          fee_amount: fee.to_f.round(2),
          anticipation_fee_amount: anticipation_fee.to_f.round(2),
          total_fee_amount: total.to_f.round(2)
        }
      end

      def build_receivable_table(receivables)
        per = [[ params.fetch(:per_page, PER_PAGE_DEFAULT).to_i, 1 ].max, PER_PAGE_MAX].min
        sort = RECEIVABLE_SORTS.fetch(params[:sort].to_s, RECEIVABLE_SORTS["payment_date"])
        direction = params[:direction].to_s.downcase == "desc" ? "DESC" : "ASC"

        paged = receivables
          .reorder(Arel.sql("#{sort} #{direction}"), id: :asc)
          .page(params[:page])
          .per(per)

        {
          rows: paged.map { |receivable| receivable_json(receivable) },
          meta: pagination_meta(paged)
        }
      end

      def receivable_json(receivable)
        {
          id: receivable.id,
          payable_id: receivable.payable_id,
          financial_source_id: receivable.financial_source_id,
          financial_source_name: receivable.financial_source&.name,
          order_id: receivable.order_id,
          order_number: receivable.order&.order_number,
          order_external_id: receivable.order&.external_id,
          status: receivable.status,
          amount: receivable.amount,
          fee_amount: receivable.fee_amount,
          anticipation_fee_amount: receivable.anticipation_fee_amount,
          total_fee_amount: (receivable.fee_amount.to_f + receivable.anticipation_fee_amount.to_f).round(2),
          net_amount: receivable.net_amount,
          payment_method: receivable.payment_method,
          installment: receivable.installment,
          payment_date: receivable.payment_date,
          original_payment_date: receivable.original_payment_date,
          charge_id: receivable.charge_id,
          transaction_id: receivable.transaction_id
        }
      end

      def parse_date_param(value)
        return nil if value.blank?

        Date.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def pagination_meta(paged)
        {
          current_page: paged.current_page,
          total_pages: paged.total_pages,
          total_count: paged.total_count,
          per_page: paged.limit_value
        }
      end

    end
  end
end
