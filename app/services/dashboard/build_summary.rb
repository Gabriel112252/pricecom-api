module Dashboard
  # Builds the full dashboard summary payload. Shared between the
  # JWT-authenticated Api::V1::DashboardController#summary and the
  # token-authenticated Api::V1::TvController#summary — both resolve a
  # tenant through different auth paths but need the exact same payload.
  class BuildSummary
    FINANCIAL_CONFLICT_TYPES = %w[
      nf_discount_mismatch nf_freight_mismatch settlement_amount_mismatch missing_settlement
    ].freeze

    def self.call(tenant:, params:)
      new(tenant: tenant, params: params).call
    end

    def initialize(tenant:, params:)
      @tenant = tenant
      @params = params
    end

    def call
      period      = resolve_period
      granularity = resolve_granularity(period)

      orders_scope = orders_in_period(period)
      prev_scope   = orders_in_period(previous_period(period))

      current_totals = period_totals(orders_scope)
      prev_totals    = period_totals(prev_scope)
      period_rows    = revenue_rows(orders_scope, granularity)

      {
        period:                   { from: period[:from].iso8601, to: period[:to].iso8601 },
        granularity:              granularity,
        revenue:                  build_revenue(orders_scope, period_rows, granularity, current_totals, prev_totals),
        margin:                   build_margin(period_rows, granularity, current_totals, prev_totals),
        orders:                   build_orders(orders_scope, granularity, current_totals, prev_totals),
        conflicts:                build_conflicts,
        reconciliation:           build_reconciliation(period),
        top_products_by_margin:   build_top_products_by_margin(period),
        top_products_by_revenue:  build_top_products_by_revenue(period),
        product_turnover_summary: build_product_turnover_summary(period)
      }
    end

    private

    attr_reader :tenant, :params

    def resolve_period
      to   = params[:to].present?   ? Date.parse(params[:to])   : Date.current
      from = params[:from].present? ? Date.parse(params[:from]) : to - 29.days
      { from: from, to: to }
    rescue ArgumentError
      { from: Date.current - 29.days, to: Date.current }
    end

    def previous_period(period)
      days    = (period[:to] - period[:from]).to_i + 1
      prev_to = period[:from] - 1.day
      { from: prev_to - (days - 1).days, to: prev_to }
    end

    def resolve_granularity(period)
      days_span = (period[:to] - period[:from]).to_i + 1
      days_span <= 1 ? "hour" : "day"
    end

    def channel_ids
      @channel_ids ||= Array(params[:channel_ids]).reject(&:blank?)
    end

    def orders_in_period(period)
      scope = tenant.orders.where(ordered_at: period[:from].beginning_of_day..period[:to].end_of_day)
      scope = scope.where(channel_id: channel_ids) if channel_ids.present?
      scope
    end

    def format_bucket(bucket, granularity)
      granularity == "hour" ? bucket.iso8601 : bucket.to_date.iso8601
    end

    def pct_change(current, previous)
      return nil if previous.nil? || previous.zero?
      ((current - previous) / previous.to_f * 100).round(2)
    end

    def period_totals(scope)
      count, gross, refund, margin = scope.pick(
        Arel.sql("COUNT(*)"),
        Arel.sql("COALESCE(SUM(gross_value), 0)"),
        Arel.sql("COALESCE(SUM(refund_amount), 0)"),
        Arel.sql("COALESCE(SUM(margin), 0)")
      ) || [0, 0, 0, 0]

      gross_f = gross.to_f
      net_f   = gross_f - refund.to_f

      {
        count:      count,
        gross:      gross_f,
        net:        net_f,
        margin:     margin.to_f,
        margin_pct: gross_f > 0 ? (margin.to_f / gross_f * 100) : 0,
        aov:        count > 0 ? (gross_f / count) : 0
      }
    end

    def revenue_rows(scope, granularity)
      trunc = granularity == "hour" ? "hour" : "day"
      scope
        .group(Arel.sql("date_trunc('#{trunc}', ordered_at)"))
        .order(Arel.sql("date_trunc('#{trunc}', ordered_at)"))
        .pluck(
          Arel.sql("date_trunc('#{trunc}', ordered_at)"),
          Arel.sql("COALESCE(SUM(gross_value), 0)"),
          Arel.sql("COALESCE(SUM(refund_amount), 0)"),
          Arel.sql("COALESCE(SUM(margin), 0)")
        )
    end

    def build_revenue(scope, rows, granularity, current_totals, prev_totals)
      by_day = rows.map do |bucket, g, r, _m|
        { date: format_bucket(bucket, granularity), gross: g.to_f.round(2), net: (g.to_f - r.to_f).round(2) }
      end

      by_channel = scope
        .joins(:channel)
        .group("channels.name")
        .sum(:gross_value)
        .transform_values { |v| v.to_f.round(2) }

      {
        gross:                 current_totals[:gross].round(2),
        net:                   current_totals[:net].round(2),
        gross_vs_previous_pct: pct_change(current_totals[:gross], prev_totals[:gross]),
        net_vs_previous_pct:   pct_change(current_totals[:net], prev_totals[:net]),
        by_day:                by_day,
        by_channel:            by_channel,
        by_channel_series:     build_revenue_channel_series(scope, granularity)
      }
    end

    def build_margin(rows, granularity, current_totals, prev_totals)
      trend = rows.map do |bucket, g, _r, m|
        gf = g.to_f
        { date: format_bucket(bucket, granularity), pct: gf > 0 ? (m.to_f / gf * 100).round(2) : 0 }
      end

      {
        avg_pct:                current_totals[:margin_pct].round(2),
        avg_pct_vs_previous_pct: pct_change(current_totals[:margin_pct], prev_totals[:margin_pct]),
        trend:                  trend
      }
    end

    def build_orders(scope, granularity, current_totals, prev_totals)
      {
        count:                   current_totals[:count],
        vs_previous_period_pct:  pct_change(current_totals[:count], prev_totals[:count]),
        aov:                     current_totals[:aov].round(2),
        aov_vs_previous_pct:     pct_change(current_totals[:aov], prev_totals[:aov]),
        by_channel_series:       build_order_channel_series(scope, granularity),
        aov_by_channel:          build_aov_by_channel(scope)
      }
    end

    def build_aov_by_channel(scope)
      rows = scope
        .joins(:channel)
        .group("channels.name")
        .pluck(Arel.sql("channels.name"), Arel.sql("COALESCE(AVG(gross_value), 0)"))

      rows.each_with_object({}) { |(name, avg), hash| hash[name] = avg.to_f.round(2) }
    end

    def build_order_channel_series(scope, granularity)
      build_channel_bucket_series(scope, granularity, "COUNT(*)", :count) { |v| v.to_i }
    end

    def build_revenue_channel_series(scope, granularity)
      build_channel_bucket_series(scope, granularity, "COALESCE(SUM(gross_value), 0)", :gross) { |v| v.to_f.round(2) }
    end

    def build_channel_bucket_series(scope, granularity, aggregate_sql, value_key)
      trunc = granularity == "hour" ? "hour" : "day"
      rows = scope
        .joins(:channel)
        .group(Arel.sql("date_trunc('#{trunc}', ordered_at)"), "channels.name")
        .pluck(Arel.sql("date_trunc('#{trunc}', ordered_at)"), Arel.sql("channels.name"), Arel.sql(aggregate_sql))

      rows.map do |bucket, channel_name, value|
        { date: format_bucket(bucket, granularity), channel: channel_name }.merge(value_key => yield(value))
      end.sort_by { |row| row[:date] }
    end

    # Deliberately NOT period-scoped: value_at_risk / oldest_open_days /
    # resolution_trend describe the tenant's CURRENT outstanding operational
    # debt, not what happened to appear inside an arbitrary date filter.
    def build_conflicts
      open_scope = tenant.audit_conflicts.open
      counts     = open_scope.group(:severity).count

      value_at_risk = open_scope
        .where(conflict_type: FINANCIAL_CONFLICT_TYPES)
        .sum(Arel.sql("ABS(difference)"))

      oldest = open_scope.order(created_at: :asc).first
      oldest_open_days = oldest ? ((Time.current - oldest.created_at) / 1.day).floor : 0

      {
        by_severity:      AuditConflict::SEVERITIES.index_with { |severity| counts[severity] || 0 },
        value_at_risk:    value_at_risk.to_f.round(2),
        oldest_open_days: oldest_open_days,
        resolution_trend: build_resolution_trend
      }
    end

    def build_resolution_trend(weeks_back: 8)
      range_start = weeks_back.weeks.ago.beginning_of_week

      opened_by_week = tenant.audit_conflicts
        .where(created_at: range_start..)
        .group(Arel.sql("date_trunc('week', created_at)"))
        .count
        .transform_keys(&:to_date)

      resolved_by_week = tenant.audit_conflicts
        .where(status: "resolved")
        .where(resolved_at: range_start..)
        .group(Arel.sql("date_trunc('week', resolved_at)"))
        .count
        .transform_keys(&:to_date)

      (0...weeks_back).map do |i|
        week_start = (range_start + i.weeks).to_date
        {
          week:     week_start.iso8601,
          opened:   opened_by_week[week_start] || 0,
          resolved: resolved_by_week[week_start] || 0
        }
      end
    end

    def build_reconciliation(period)
      items = FinancialSettlementItem
        .where(tenant_id: tenant.id)
        .where(transaction_date: period[:from].beginning_of_day..period[:to].end_of_day)

      status_counts = items.group(:status).count
      total     = status_counts.values.sum
      matched   = status_counts["matched"]   || 0
      disputed  = status_counts["disputed"]  || 0
      unmatched = status_counts["unmatched"] || 0

      by_source_rows = items
        .joins(financial_settlement: :financial_source)
        .group(Arel.sql("financial_sources.name"))
        .pluck(
          Arel.sql("financial_sources.name"),
          Arel.sql("COUNT(*)"),
          Arel.sql("COUNT(*) FILTER (WHERE financial_settlement_items.status = 'matched')"),
          Arel.sql("COUNT(*) FILTER (WHERE financial_settlement_items.status = 'disputed')"),
          Arel.sql("COUNT(*) FILTER (WHERE financial_settlement_items.status = 'unmatched')")
        )

      by_source = by_source_rows.each_with_object({}) do |(name, source_total, source_matched, source_disputed, source_unmatched), hash|
        hash[name] = {
          matched_pct: source_total > 0 ? (source_matched.to_f / source_total * 100).round(2) : 0,
          disputed:    source_disputed,
          unmatched:   source_unmatched
        }
      end

      {
        matched_pct: total > 0 ? (matched.to_f / total * 100).round(2) : 0,
        disputed:    disputed,
        unmatched:   unmatched,
        by_source:   by_source
      }
    end

    def build_top_products_by_margin(period)
      rows = OrderItem
        .joins(:order, :product)
        .where(orders: { tenant_id: tenant.id, ordered_at: period_range(period) })
        .where(is_gift: false)
        .group("products.id", "products.sku", "products.name")
        .having("SUM(order_items.quantity * order_items.unit_price - order_items.discount) > 0")
        .order(Arel.sql(
          "(SUM(order_items.quantity * order_items.unit_price - order_items.discount) " \
          "- SUM(order_items.quantity * order_items.unit_cost)) " \
          "/ SUM(order_items.quantity * order_items.unit_price - order_items.discount) DESC"
        ))
        .limit(10)
        .pluck(
          Arel.sql("products.sku"),
          Arel.sql("products.name"),
          Arel.sql("SUM(order_items.quantity * order_items.unit_price - order_items.discount)"),
          Arel.sql("SUM(order_items.quantity * order_items.unit_cost)")
        )

      rows.map do |sku, name, revenue, cost|
        revenue_f = revenue.to_f
        margin_pct = revenue_f > 0 ? ((revenue_f - cost.to_f) / revenue_f * 100).round(2) : 0
        { sku: sku, name: name, margin_pct: margin_pct }
      end
    end

    def build_top_products_by_revenue(period)
      rows = OrderItem
        .joins(:order, :product)
        .where(orders: { tenant_id: tenant.id, ordered_at: period_range(period) })
        .where(is_gift: false)
        .group("products.id", "products.sku", "products.name")
        .order(Arel.sql("SUM(order_items.quantity * order_items.unit_price - order_items.discount) DESC"))
        .limit(10)
        .pluck(
          Arel.sql("products.sku"),
          Arel.sql("products.name"),
          Arel.sql("SUM(order_items.quantity * order_items.unit_price - order_items.discount)")
        )

      rows.map { |sku, name, revenue| { sku: sku, name: name, revenue: revenue.to_f.round(2) } }
    end

    # Tenant-wide version of ProductsController#turnover / #compute_kit_sales_qty:
    # a single pass over every kit sale in the period, aggregating real
    # (post-explosion) quantity per leaf product instead of just one product.
    def build_product_turnover_summary(period, limit: 15)
      items = OrderItem
        .joins(:order, :product)
        .where(orders: { tenant_id: tenant.id, ordered_at: period_range(period) })
        .where(is_gift: false)

      direct = items.group("products.id", "products.sku", "products.name").sum(:quantity)

      combined = {}
      direct.each do |(id, sku, name), qty|
        combined[id] = { id: id, sku: sku, name: name, direct_qty: qty.to_f, kit_qty: 0.0 }
      end

      items.where(products: { is_kit: true })
        .includes(product: { kit_components: { component_product: { kit_components: :component_product } } })
        .find_each do |item|
          Products::ExplodeKit.call(item.product, item.quantity).each do |leaf|
            entry = combined[leaf[:product].id] ||= {
              id: leaf[:product].id, sku: leaf[:product].sku, name: leaf[:product].name,
              direct_qty: 0.0, kit_qty: 0.0
            }
            entry[:kit_qty] += leaf[:real_qty].to_f
          end
        end

      combined.values
        .map { |e| e.merge(total_qty: e[:direct_qty] + e[:kit_qty], kit_only: e[:direct_qty].zero? && e[:kit_qty] > 0) }
        .sort_by { |e| -e[:total_qty] }
        .first(limit)
    end

    def period_range(period)
      period[:from].beginning_of_day..period[:to].end_of_day
    end
  end
end
