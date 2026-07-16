module Dashboard
  # Builds the full dashboard summary payload. Shared between the
  # JWT-authenticated Api::V1::DashboardController#summary and the
  # token-authenticated Api::V1::TvController#summary — both resolve a
  # tenant through different auth paths but need the exact same payload.
  class BuildSummary
    FINANCIAL_CONFLICT_TYPES = %w[
      nf_discount_mismatch nf_freight_mismatch settlement_amount_mismatch missing_settlement
    ].freeze
    CANCELED_STATUS_ALIASES = %w[cancelado canceled cancelled cancelada].freeze
    BRAZIL_STATES = {
      "AC" => "Acre",
      "AL" => "Alagoas",
      "AP" => "Amapá",
      "AM" => "Amazonas",
      "BA" => "Bahia",
      "CE" => "Ceará",
      "DF" => "Distrito Federal",
      "ES" => "Espírito Santo",
      "GO" => "Goiás",
      "MA" => "Maranhão",
      "MT" => "Mato Grosso",
      "MS" => "Mato Grosso do Sul",
      "MG" => "Minas Gerais",
      "PA" => "Pará",
      "PB" => "Paraíba",
      "PR" => "Paraná",
      "PE" => "Pernambuco",
      "PI" => "Piauí",
      "RJ" => "Rio de Janeiro",
      "RN" => "Rio Grande do Norte",
      "RS" => "Rio Grande do Sul",
      "RO" => "Rondônia",
      "RR" => "Roraima",
      "SC" => "Santa Catarina",
      "SP" => "São Paulo",
      "SE" => "Sergipe",
      "TO" => "Tocantins"
    }.freeze
    BRAZIL_STATE_ALIASES = BRAZIL_STATES.each_with_object({}) do |(uf, name), hash|
      hash[uf] = uf
      hash[name.upcase] = uf
      hash[I18n.transliterate(name).upcase] = uf
    end.freeze

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

      orders_scope = financial_orders(orders_in_period(period))
      prev_scope   = financial_orders(orders_in_period(previous_period(period)))

      current_totals = period_totals(orders_scope)
      prev_totals    = period_totals(prev_scope)
      period_rows    = revenue_rows(orders_scope, granularity)
      data_quality   = build_data_quality(orders_scope)
      coupons        = build_coupons(orders_scope)
      regional_sales = build_regional_sales(orders_scope, current_totals)

      {
        period:                   { from: period[:from].iso8601, to: period[:to].iso8601 },
        granularity:              granularity,
        kpis:                     build_kpis(current_totals, prev_totals, data_quality, coupons, regional_sales),
        financial_composition:    build_financial_composition(current_totals, data_quality),
        revenue_timeline:         build_revenue_timeline(period_rows, granularity),
        sales_by_channel:         build_sales_by_channel(orders_scope, current_totals),
        regional_sales:           regional_sales,
        coupons:                  coupons,
        revenue:                  build_revenue(orders_scope, period_rows, granularity, current_totals, prev_totals),
        financial:                build_financial(current_totals, prev_totals, data_quality),
        margin:                   build_margin(period_rows, granularity, current_totals, prev_totals, data_quality),
        orders:                   build_orders(orders_scope, granularity, current_totals, prev_totals),
        data_sources:             build_data_sources,
        data_quality:             data_quality,
        conflicts:                build_conflicts,
        reconciliation:           build_reconciliation(period),
        cart_abandonment:         build_cart_abandonment(period),
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

    def financial_orders(scope)
      scope
        .where(order_type: %w[sale refund])
        .where.not("LOWER(COALESCE(status, '')) IN (?)", CANCELED_STATUS_ALIASES)
    end

    def format_bucket(bucket, granularity)
      granularity == "hour" ? bucket.iso8601 : bucket.to_date.iso8601
    end

    def pct_change(current, previous)
      return nil if previous.nil? || previous.to_f.abs < 0.01
      ((current - previous) / previous.to_f * 100).round(2)
    end

    def period_totals(scope)
      count, gross, refund, discount_amount, commission_amount, operational_cost = scope.pick(
        Arel.sql("COUNT(*)"),
        Arel.sql("COALESCE(SUM(gross_value), 0)"),
        Arel.sql("COALESCE(SUM(refund_amount), 0)"),
        Arel.sql("COALESCE(SUM(discount), 0)"),
        Arel.sql("COALESCE(SUM(commission), 0)"),
        Arel.sql("COALESCE(SUM(operational_cost), 0)")
      ) || [0, 0, 0, 0, 0, 0]

      gross_f = gross.to_f
      discounts_f = discount_amount.to_f
      refunds_f = refund.to_f
      net_f = gross_f - discounts_f - refunds_f
      product_cost_f = product_cost_for(scope)
      freight_f = freight_for(scope)
      taxes_f = taxes_for(scope)
      result_f = net_f - product_cost_f - freight_f - commission_amount.to_f - taxes_f - operational_cost.to_f

      {
        count:            count,
        gross:            gross_f,
        net:              net_f,
        refunds:          refunds_f,
        product_cost:     product_cost_f,
        freight:          freight_f,
        discounts:        discounts_f,
        commissions:      commission_amount.to_f,
        operational_cost: operational_cost.to_f,
        taxes:            taxes_f,
        result:           result_f,
        profit:           result_f,
        margin:           result_f,
        margin_pct:       net_f > 0 ? (result_f / net_f * 100) : 0,
        aov:              count > 0 ? (net_f / count) : 0,
        discounts_pct:    gross_f > 0 ? (discounts_f / gross_f * 100) : 0
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
          Arel.sql("COALESCE(SUM(discount), 0)"),
          Arel.sql("COUNT(*)")
        )
    end

    def build_revenue(scope, rows, granularity, current_totals, prev_totals)
      by_day = build_revenue_timeline(rows, granularity)

      by_channel = scope
        .joins(:channel)
        .group("channels.name")
        .sum(Arel.sql("COALESCE(gross_value, 0) - COALESCE(discount, 0) - COALESCE(refund_amount, 0)"))
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

    def build_financial(current_totals, prev_totals, data_quality)
      product_cost = current_totals[:product_cost].round(2)
      financial_available = data_quality[:financial_status] == "complete"

      {
        product_cost: product_cost,
        freight: current_totals[:freight].round(2),
        taxes: current_totals[:taxes].round(2),
        discounts: current_totals[:discounts].round(2),
        commissions: current_totals[:commissions].round(2),
        operational_cost: current_totals[:operational_cost].round(2),
        refunds: current_totals[:refunds].round(2),
        profit: financial_available ? current_totals[:profit].round(2) : nil,
        margin: financial_available ? current_totals[:margin].round(2) : nil,
        margin_pct: financial_available ? current_totals[:margin_pct].round(2) : nil,
        profit_available: financial_available,
        margin_available: financial_available,
        unavailable_reason: financial_available ? nil : data_quality[:financial_status_reason],
        product_cost_vs_previous_pct: pct_change(product_cost, prev_totals[:product_cost]),
        profit_vs_previous_pct: financial_available ? pct_change(current_totals[:profit], prev_totals[:profit]) : nil
      }
    end

    def build_margin(rows, granularity, current_totals, prev_totals, data_quality)
      trend = []
      financial_available = data_quality[:financial_status] == "complete"

      {
        avg_pct:                  financial_available ? current_totals[:margin_pct].round(2) : nil,
        avg_pct_vs_previous_pct:  financial_available ? pct_change(current_totals[:margin_pct], prev_totals[:margin_pct]) : nil,
        available:                financial_available,
        unavailable_reason:       financial_available ? nil : data_quality[:financial_status_reason],
        trend:                    trend
      }
    end

    def build_kpis(current_totals, prev_totals, data_quality, coupons, regional_sales)
      margin_available = data_quality[:financial_status] == "complete"
      top_state = regional_sales[:top_state]

      {
        gross_revenue: current_totals[:gross].round(2),
        net_revenue: current_totals[:net].round(2),
        net_revenue_vs_previous_pct: pct_change(current_totals[:net], prev_totals[:net]),
        orders_count: current_totals[:count],
        orders_vs_previous_pct: pct_change(current_totals[:count], prev_totals[:count]),
        average_ticket: current_totals[:aov].round(2),
        average_ticket_vs_previous_pct: pct_change(current_totals[:aov], prev_totals[:aov]),
        discounts_total: current_totals[:discounts].round(2),
        discounts_percentage: current_totals[:discounts_pct].round(2),
        contribution_margin: margin_available ? current_totals[:margin_pct].round(2) : nil,
        contribution_margin_available: margin_available,
        contribution_margin_unavailable_reason: margin_available ? nil : data_quality[:financial_status_reason],
        financial_coverage_percentage: data_quality[:coverage_percentage],
        complete_orders_count: data_quality[:complete_orders_count],
        incomplete_orders_count: data_quality[:incomplete_orders_count],
        coupon_discount_total: coupons[:display_discount_total],
        coupon_orders_count: coupons[:display_orders_count],
        coupon_usage_percentage: coupons[:usage_percentage],
        coupon_codes_count: coupons[:codes_count],
        uncoded_discount_total: coupons[:uncoded_discount_total],
        uncoded_discount_orders_count: coupons[:uncoded_discount_orders_count],
        commercial_discount_total: coupons[:commercial_discount_total],
        commercial_discount_orders_count: coupons[:commercial_discount_orders_count],
        shipping_subsidy_total: coupons[:shipping_subsidy_total],
        shipping_subsidy_orders_count: coupons[:shipping_subsidy_orders_count],
        top_region_state: top_state&.dig(:state),
        top_region_name: top_state&.dig(:name),
        top_region_orders_count: top_state&.dig(:orders_count),
        top_region_net_revenue: top_state&.dig(:net_revenue)
      }
    end

    def build_financial_composition(current_totals, data_quality)
      result_available = data_quality[:financial_status] == "complete"
      incomplete_reason = data_quality[:financial_status_reason]

      {
        gross_revenue: composition_line(current_totals[:gross], "available", "Soma de gross_value dos pedidos válidos."),
        discounts: composition_line(current_totals[:discounts], "available", "Soma de discount dos pedidos válidos."),
        refunds: composition_line(current_totals[:refunds], "available", "Soma de refund_amount dos pedidos válidos."),
        net_revenue: composition_line(current_totals[:net], "available", "Receita bruta menos descontos e reembolsos."),
        product_cost: composition_line(
          current_totals[:product_cost],
          data_quality[:missing_cost_orders_count].positive? ? "incomplete" : "available",
          "CMV calculado por order_items.quantity x order_items.unit_cost para itens com custo conhecido.",
          data_quality[:missing_cost_orders_count].positive? ? "Existem pedidos com item sem custo completo." : nil
        ),
        freight: composition_line(
          current_totals[:freight],
          data_quality[:orders_without_freight].positive? ? "incomplete" : "available",
          freight_tooltip,
          data_quality[:orders_without_freight].positive? ? "Existem pedidos sem frete real." : nil
        ),
        commissions: composition_line(current_totals[:commissions], "available", "Soma de commission persistida nos pedidos."),
        taxes: composition_line(
          tax_source_configured? ? current_totals[:taxes] : nil,
          tax_source_configured? ? (data_quality[:orders_without_tax].positive? ? "incomplete" : "available") : "not_configured",
          tax_source_configured? ? "Soma de tax_amount dos pedidos." : "Nenhuma fonte de impostos configurada no Pricecom.",
          data_quality[:orders_without_tax].positive? ? "Existem pedidos sem imposto." : nil
        ),
        operational_costs: composition_line(current_totals[:operational_cost], "available", "Soma de operational_cost persistida nos pedidos."),
        result: composition_line(
          result_available ? current_totals[:result] : nil,
          result_available ? "available" : "incomplete",
          "Receita líquida - CMV - frete - comissões - impostos - custos operacionais.",
          result_available ? nil : incomplete_reason
        ),
        result_available: result_available,
        result_unavailable_reason: result_available ? nil : incomplete_reason
      }
    end

    def build_revenue_timeline(rows, granularity)
      rows.map do |bucket, gross, refund, discount, orders_count|
        gross_f = gross.to_f
        discounts_f = discount.to_f
        refunds_f = refund.to_f
        net_f = gross_f - discounts_f - refunds_f
        orders_count_i = orders_count.to_i

        {
          date: format_bucket(bucket, granularity),
          gross: gross_f.round(2),
          discounts: discounts_f.round(2),
          refunds: refunds_f.round(2),
          net: net_f.round(2),
          orders_count: orders_count_i,
          average_ticket: orders_count_i.positive? ? (net_f / orders_count_i).round(2) : 0
        }
      end
    end

    def build_sales_by_channel(scope, current_totals)
      rows = scope
        .joins(:channel)
        .group("channels.id", "channels.name")
        .pluck(
          Arel.sql("channels.name"),
          Arel.sql("COUNT(*)"),
          Arel.sql("COALESCE(SUM(gross_value), 0)"),
          Arel.sql("COALESCE(SUM(discount), 0)"),
          Arel.sql("COALESCE(SUM(refund_amount), 0)")
        )

      total_net = current_totals[:net]
      rows.filter_map do |name, count, gross, discount, refund|
        count_i = count.to_i
        next if count_i.zero?

        gross_f = gross.to_f
        discount_f = discount.to_f
        refund_f = refund.to_f
        net_f = gross_f - discount_f - refund_f

        {
          channel: name,
          net_revenue: net_f.round(2),
          gross_revenue: gross_f.round(2),
          discounts: discount_f.round(2),
          refunds: refund_f.round(2),
          orders_count: count_i,
          average_ticket: count_i.positive? ? (net_f / count_i).round(2) : 0,
          share_percentage: total_net.positive? ? (net_f / total_net * 100).round(2) : 0
        }
      end.sort_by { |row| -row[:net_revenue] }
    end

    def build_regional_sales(scope, current_totals)
      rows = scope
        .group(:state)
        .pluck(
          :state,
          Arel.sql("COUNT(*)"),
          Arel.sql("COALESCE(SUM(gross_value), 0)"),
          Arel.sql("COALESCE(SUM(discount), 0)"),
          Arel.sql("COALESCE(SUM(refund_amount), 0)")
        )

      aggregate = Hash.new { |hash, uf| hash[uf] = { orders_count: 0, net_revenue: 0.0, gross_revenue: 0.0 } }
      unknown_orders = 0

      rows.each do |raw_state, count, gross, discount, refund|
        uf = normalize_state(raw_state)
        if uf.blank?
          unknown_orders += count.to_i
          next
        end

        gross_f = gross.to_f
        net_f = gross_f - discount.to_f - refund.to_f
        aggregate[uf][:orders_count] += count.to_i
        aggregate[uf][:net_revenue] += net_f
        aggregate[uf][:gross_revenue] += gross_f
      end

      states = BRAZIL_STATES.map do |uf, name|
        values = aggregate[uf]
        {
          state: uf,
          name: name,
          orders_count: values[:orders_count],
          net_revenue: values[:net_revenue].round(2),
          gross_revenue: values[:gross_revenue].round(2),
          share_percentage: current_totals[:count].positive? ? (values[:orders_count].to_f / current_totals[:count] * 100).round(2) : 0
        }
      end

      ranked = states.select { |state| state[:orders_count].positive? }.sort_by { |state| [-state[:orders_count], -state[:net_revenue]] }

      {
        states: states,
        top_state: ranked.first,
        top_states: ranked.first(8),
        unknown_orders_count: unknown_orders,
        total_orders_count: current_totals[:count]
      }
    end

    def build_coupons(scope)
      return empty_coupons unless order_has_coupons?

      coupon_value_sql = "CASE WHEN COALESCE(coupon_discount, 0) > 0 THEN coupon_discount ELSE COALESCE(discount, 0) END"
      shipping_subsidy_sql = "CASE WHEN real_freight_cost IS NOT NULL AND COALESCE(real_freight_cost, 0) > COALESCE(freight, 0) THEN COALESCE(real_freight_cost, 0) - COALESCE(freight, 0) ELSE 0 END"
      coupon_predicate = "coupon_code IS NOT NULL AND TRIM(coupon_code) <> ''"
      uncoded_discount_predicate = "(coupon_code IS NULL OR TRIM(coupon_code) = '') AND COALESCE(discount, 0) > 0"
      shipping_subsidy_predicate = "real_freight_cost IS NOT NULL AND COALESCE(real_freight_cost, 0) > COALESCE(freight, 0)"
      coupon_scope = scope.where(coupon_predicate)
      uncoded_discount_scope = scope.where(uncoded_discount_predicate)
      shipping_subsidy_scope = scope.where(shipping_subsidy_predicate)
      incentive_scope = scope.where("(#{coupon_predicate}) OR (#{uncoded_discount_predicate}) OR (#{shipping_subsidy_predicate})")
      total_orders = scope.count
      orders_count = coupon_scope.count
      total_discount = coupon_scope.sum(Arel.sql(coupon_value_sql)).to_f
      uncoded_discount_total = uncoded_discount_scope.sum(:discount).to_f
      uncoded_discount_orders_count = uncoded_discount_scope.count
      shipping_subsidy_total = scope.sum(Arel.sql(shipping_subsidy_sql)).to_f
      shipping_subsidy_orders_count = shipping_subsidy_scope.count
      rows = coupon_scope
        .group(Arel.sql("UPPER(TRIM(coupon_code))"))
        .pluck(
          Arel.sql("UPPER(TRIM(coupon_code))"),
          Arel.sql("COUNT(*)"),
          Arel.sql("COALESCE(SUM(#{coupon_value_sql}), 0)"),
          Arel.sql("COALESCE(SUM(COALESCE(gross_value, 0) - COALESCE(discount, 0) - COALESCE(refund_amount, 0)), 0)")
        )

      top_coupons = rows.map do |code, count, discount, net_revenue|
        {
          code: code,
          orders_count: count.to_i,
          discount_total: discount.to_f.round(2),
          net_revenue: net_revenue.to_f.round(2)
        }
      end.sort_by { |row| [-row[:orders_count], -row[:discount_total]] }.first(10)

      commercial_discount_total = uncoded_discount_total
      commercial_discount_orders_count = uncoded_discount_orders_count
      display_discount_total = total_discount + commercial_discount_total + shipping_subsidy_total
      display_orders_count = incentive_scope.count
      breakdown = discount_breakdown(
        coupon_discount_total: total_discount,
        coupon_orders_count: orders_count,
        commercial_discount_total: commercial_discount_total,
        commercial_discount_orders_count: commercial_discount_orders_count,
        shipping_subsidy_total: shipping_subsidy_total,
        shipping_subsidy_orders_count: shipping_subsidy_orders_count
      )

      {
        available: true,
        has_coupon_codes: orders_count.positive?,
        total_discount: total_discount.round(2),
        display_discount_total: display_discount_total.round(2),
        orders_count: orders_count,
        display_orders_count: display_orders_count,
        codes_count: rows.size,
        uncoded_discount_total: uncoded_discount_total.round(2),
        uncoded_discount_orders_count: uncoded_discount_orders_count,
        commercial_discount_total: commercial_discount_total.round(2),
        commercial_discount_orders_count: commercial_discount_orders_count,
        shipping_subsidy_total: shipping_subsidy_total.round(2),
        shipping_subsidy_orders_count: shipping_subsidy_orders_count,
        usage_percentage: total_orders.positive? ? (display_orders_count.to_f / total_orders * 100).round(2) : 0,
        breakdown: breakdown,
        top_coupons: top_coupons,
        by_product: build_discount_by_product(scope)
      }
    end

    # Item-level discount composition — which products concentrate the
    # discounts given in the period. Uses order_items.discount (populated by
    # the channel normalizers), so it only sees discounts the channel
    # attributes to a specific item; order-level discounts with no item
    # split stay out of this cut (they're covered by the type breakdown).
    def build_discount_by_product(scope)
      rows = OrderItem
        .where(order_id: scope.select(:id), is_gift: false)
        .where("COALESCE(order_items.discount, 0) > 0")
        .group(:sku, :name)
        .order(Arel.sql("COALESCE(SUM(order_items.discount), 0) DESC"))
        .limit(10)
        .pluck(
          :sku,
          :name,
          Arel.sql("COALESCE(SUM(order_items.discount), 0)"),
          Arel.sql("COUNT(DISTINCT order_items.order_id)")
        )

      rows.map do |sku, name, discount_total, orders_count|
        {
          sku: sku,
          name: name.presence || sku,
          discount_total: discount_total.to_f.round(2),
          orders_count: orders_count.to_i
        }
      end
    end

    def discount_breakdown(coupon_discount_total:, coupon_orders_count:, commercial_discount_total:, commercial_discount_orders_count:, shipping_subsidy_total:, shipping_subsidy_orders_count:)
      [
        {
          key: "coupon",
          label: "Cupons identificados",
          amount: coupon_discount_total.round(2),
          orders_count: coupon_orders_count,
          evidence: "Pedidos com coupon_code preenchido."
        },
        {
          key: "commercial_discount",
          label: "Desconto progressivo / comercial",
          amount: commercial_discount_total.round(2),
          orders_count: commercial_discount_orders_count,
          evidence: "Pedidos com discount maior que zero e sem codigo de cupom capturado."
        },
        {
          key: "shipping_subsidy",
          label: "Subsídio de frete",
          amount: shipping_subsidy_total.round(2),
          orders_count: shipping_subsidy_orders_count,
          evidence: "Estimado quando real_freight_cost e maior que o frete cobrado do cliente."
        }
      ]
    end

    def build_data_sources
      DataSourceConfig::DATA_TYPES.each_with_object({}) do |data_type, hash|
        hash[data_type] = {
          source: data_source_for(data_type),
          available_sources: DataSourceConfig.available_sources_for(data_type)
        }
      end
    end

    def build_data_quality(scope)
      items = OrderItem.where(order_id: scope.select(:id))
      non_gift_items = items.where(is_gift: false)
      latest_idworks_cost_log = tenant.integration_sync_logs
        .where(action: "idworks_product_cost_sync")
        .order(created_at: :desc)
        .first
      log_metadata = latest_idworks_cost_log&.metadata || {}

      latest_yampi_log = tenant.integration_sync_logs
        .where(action: "yampi_order_polling")
        .order(created_at: :desc)
        .first
      latest_idworks_order_log = tenant.integration_sync_logs
        .where(action: "idworks_order_sync")
        .order(created_at: :desc)
        .first
      order_ids_with_items = non_gift_items.distinct.pluck(:order_id)
      missing_item_order_ids = scope.where.not(id: order_ids_with_items).pluck(:id)
      missing_cost_order_ids = (missing_item_order_ids + non_gift_items
        .where("order_items.product_id IS NULL OR order_items.unit_cost IS NULL OR order_items.unit_cost <= 0")
        .distinct
        .pluck(:order_id)).uniq
      missing_freight_order_ids = data_source_for("freight") == "idworks" ? scope.where(real_freight_cost: nil).pluck(:id) : []
      missing_tax_order_ids = tax_source_configured? ? scope.where(tax_amount: nil).pluck(:id) : []
      incomplete_order_ids = (missing_cost_order_ids + missing_freight_order_ids + missing_tax_order_ids).uniq
      total_orders = scope.count
      complete_orders = total_orders - incomplete_order_ids.size
      coverage = total_orders.positive? ? (complete_orders.to_f / total_orders * 100).round(2) : 100.0
      status = coverage >= 95 ? "healthy" : coverage >= 70 ? "attention" : "critical"
      incomplete_reasons = []
      incomplete_reasons << "#{missing_cost_order_ids.size} pedido(s) sem custo completo" if missing_cost_order_ids.any?
      incomplete_reasons << "#{missing_freight_order_ids.size} pedido(s) sem frete real" if missing_freight_order_ids.any?
      incomplete_reasons << "#{missing_tax_order_ids.size} pedido(s) sem imposto" if missing_tax_order_ids.any?
      financial_status_reason = incomplete_order_ids.empty? ? nil : "Indisponível — #{incomplete_reasons.join(', ')}."

      {
        complete_orders_count: complete_orders,
        incomplete_orders_count: incomplete_order_ids.size,
        missing_cost_orders_count: missing_cost_order_ids.size,
        orders_without_cost: missing_cost_order_ids.size,
        order_items_without_cost: non_gift_items.where("unit_cost IS NULL OR unit_cost = 0").count,
        order_items_without_product: non_gift_items.where(product_id: nil).count,
        orders_without_freight: missing_freight_order_ids.size,
        orders_without_tax: missing_tax_order_ids.size,
        coverage_percentage: coverage,
        financial_coverage_percentage: coverage,
        financial_status: incomplete_order_ids.empty? ? "complete" : "incomplete",
        financial_status_reason: financial_status_reason,
        health_status: status,
        products_without_sku_match: log_metadata["unmatched_count"].to_i,
        unmatched_skus_count: log_metadata["unmatched_count"].to_i,
        latest_idworks_product_cost_sync_at: latest_idworks_cost_log&.finished_at,
        latest_idworks_order_sync_at: latest_idworks_order_log&.finished_at,
        latest_idworks_sync_at: [latest_idworks_cost_log&.finished_at, latest_idworks_order_log&.finished_at].compact.max,
        latest_yampi_order_sync_at: latest_yampi_log&.finished_at,
        latest_idworks_unmatched_skus: Array(log_metadata["unmatched"]).first(10)
      }.merge(integration_health_metadata(latest_yampi_log, latest_idworks_cost_log, latest_idworks_order_log))
    end

    def integration_health_metadata(latest_yampi_log, latest_idworks_cost_log, latest_idworks_order_log)
      delayed = []
      error_logs = tenant.integration_sync_logs
        .where(action: %w[yampi_order_polling idworks_product_cost_sync idworks_order_sync])
        .where(status: "error")
        .order(created_at: :desc)
        .limit(5)

      yampi_credentials = tenant.channel_credentials.where(channel: "yampi", status: "active")
      yampi_credentials = yampi_credentials.where(polling_enabled: true) if ChannelCredential.column_names.include?("polling_enabled")

      if yampi_credentials.exists?
        last_yampi_at = latest_yampi_log&.finished_at
        delayed << { provider: "yampi", reason: "polling atrasado" } if last_yampi_at.nil? || last_yampi_at < 15.minutes.ago
      end

      if tenant.integrations.where(provider: "idworks", status: "connected").exists?
        latest_idworks_at = [latest_idworks_cost_log&.finished_at, latest_idworks_order_log&.finished_at].compact.max
        delayed << { provider: "idworks", reason: "sincronização atrasada" } if latest_idworks_at.nil? || latest_idworks_at < 12.hours.ago
      end

      {
        delayed_integrations: delayed,
        integration_errors: error_logs.map { |log|
          {
            action: log.action,
            status: log.status,
            error_message: log.error_message,
            finished_at: log.finished_at
          }
        }
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
        .pluck(
          Arel.sql("channels.name"),
          Arel.sql("COALESCE(AVG(COALESCE(gross_value, 0) - COALESCE(discount, 0) - COALESCE(refund_amount, 0)), 0)")
        )

      rows.each_with_object({}) { |(name, avg), hash| hash[name] = avg.to_f.round(2) }
    end

    def build_order_channel_series(scope, granularity)
      build_channel_bucket_series(scope, granularity, "COUNT(*)", :count) { |v| v.to_i }
    end

    def build_revenue_channel_series(scope, granularity)
      build_channel_bucket_series(
        scope,
        granularity,
        "COALESCE(SUM(COALESCE(gross_value, 0) - COALESCE(discount, 0) - COALESCE(refund_amount, 0)), 0)",
        :gross
      ) { |v| v.to_f.round(2) }
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
        .where("order_items.unit_cost IS NOT NULL AND order_items.unit_cost > 0")
        .group("products.id", "products.sku", "products.name")
        .having("SUM(order_items.quantity * order_items.unit_price - order_items.discount) > 0")
        .order(Arel.sql(
          "(SUM(order_items.quantity * order_items.unit_price - order_items.discount) " \
          "- SUM(#{item_cost_amount_sql})) " \
          "/ SUM(order_items.quantity * order_items.unit_price - order_items.discount) DESC"
        ))
        .limit(10)
        .pluck(
          Arel.sql("products.sku"),
          Arel.sql("products.name"),
          Arel.sql("SUM(order_items.quantity * order_items.unit_price - order_items.discount)"),
          Arel.sql("SUM(#{item_cost_amount_sql})")
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

    # Abandoned-cart panel (Yampi-only for now — carts are only ingested by
    # the Yampi polling/webhook pipeline). Scoped by abandoned_at, honoring
    # the same channel filter as the rest of the summary. Guarded so the
    # summary keeps working before the carts migration has run.
    def build_cart_abandonment(period)
      return empty_cart_abandonment unless carts_available?

      scope = tenant.carts.where(abandoned_at: period_range(period))
      scope = scope.where(channel_id: channel_ids) if channel_ids.present?

      total_count, converted_count, abandoned_count, abandoned_value, converted_value,
        promocode, progressive, combos, shipment_discount = scope.pick(
          Arel.sql("COUNT(*)"),
          Arel.sql("COUNT(*) FILTER (WHERE status = 'converted')"),
          Arel.sql("COUNT(*) FILTER (WHERE status = 'abandoned')"),
          Arel.sql("COALESCE(SUM(total) FILTER (WHERE status = 'abandoned'), 0)"),
          Arel.sql("COALESCE(SUM(total) FILTER (WHERE status = 'converted'), 0)"),
          Arel.sql("COALESCE(SUM(promocode_discount), 0)"),
          Arel.sql("COALESCE(SUM(progressive_discount), 0)"),
          Arel.sql("COALESCE(SUM(combos_discount), 0)"),
          Arel.sql("COALESCE(SUM(shipment_discount), 0)")
        ) || Array.new(9, 0)

      total_count = total_count.to_i
      converted_count = converted_count.to_i

      {
        available: true,
        total_count: total_count,
        recovered: {
          count: converted_count,
          value: converted_value.to_f.round(2)
        },
        still_abandoned: {
          count: abandoned_count.to_i,
          value: abandoned_value.to_f.round(2)
        },
        conversion_rate_pct: total_count.positive? ? (converted_count.to_f / total_count * 100).round(2) : 0.0,
        discount_composition: [
          { key: "coupon", label: "Cupom", amount: promocode.to_f.round(2) },
          { key: "progressive", label: "Desconto progressivo", amount: progressive.to_f.round(2) },
          { key: "combo", label: "Combos", amount: combos.to_f.round(2) },
          { key: "shipping", label: "Desconto de frete", amount: shipment_discount.to_f.round(2) }
        ]
      }
    end

    def carts_available?
      return @carts_available if defined?(@carts_available)

      @carts_available = Cart.table_exists?
    rescue StandardError
      @carts_available = false
    end

    def empty_cart_abandonment
      {
        available: false,
        total_count: 0,
        recovered: { count: 0, value: 0.0 },
        still_abandoned: { count: 0, value: 0.0 },
        conversion_rate_pct: 0.0,
        discount_composition: []
      }
    end

    def data_source_for(data_type)
      @data_sources ||= tenant.data_source_configs.enabled.pluck(:data_type, :source).to_h
      @data_sources[data_type]
    end

    def normalize_state(value)
      normalized = I18n.transliterate(value.to_s).strip.upcase
      normalized = normalized.gsub(/\AESTADO DE\s+/, "")
      BRAZIL_STATE_ALIASES[normalized]
    end

    def order_has_coupons?
      @order_has_coupons ||= Order.column_names.include?("coupon_code")
    end

    def empty_coupons
      {
        available: false,
        has_coupon_codes: false,
        total_discount: 0.0,
        display_discount_total: 0.0,
        orders_count: 0,
        display_orders_count: 0,
        codes_count: 0,
        uncoded_discount_total: 0.0,
        uncoded_discount_orders_count: 0,
        commercial_discount_total: 0.0,
        commercial_discount_orders_count: 0,
        shipping_subsidy_total: 0.0,
        shipping_subsidy_orders_count: 0,
        usage_percentage: 0.0,
        breakdown: [],
        top_coupons: [],
        by_product: []
      }
    end

    def product_cost_for(scope)
      item_scope_for(scope)
        .where("unit_cost IS NOT NULL AND unit_cost > 0")
        .sum(Arel.sql("quantity * unit_cost"))
        .to_f
    end

    def freight_for(scope)
      if data_source_for("freight") == "idworks"
        scope.where.not(real_freight_cost: nil).sum(:real_freight_cost).to_f
      else
        scope.sum(:freight).to_f
      end
    end

    def taxes_for(scope)
      tax_source_configured? ? scope.where.not(tax_amount: nil).sum(:tax_amount).to_f : 0.0
    end

    def tax_source_configured?
      data_source_for("tax").present?
    end

    def freight_tooltip
      data_source_for("freight") == "idworks" ? "Soma de real_freight_cost importado do IDWorks." : "Soma de freight dos pedidos."
    end

    def composition_line(value, status, tooltip, reason = nil)
      {
        value: value&.to_f&.round(2),
        available: status == "available",
        status: status,
        tooltip: tooltip,
        reason: reason
      }
    end

    def item_scope_for(scope)
      OrderItem.where(order_id: scope.select(:id), is_gift: false)
    end

    def item_cost_amount_sql
      "order_items.quantity * order_items.unit_cost"
    end
  end
end
