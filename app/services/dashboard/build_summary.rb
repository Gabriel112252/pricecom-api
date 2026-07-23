module Dashboard
  # Builds the full dashboard summary payload. Shared between the
  # JWT-authenticated Api::V1::DashboardController#summary and the
  # token-authenticated Api::V1::TvController#summary — both resolve a
  # tenant through different auth paths but need the exact same payload.
  class BuildSummary
    FINANCIAL_CONFLICT_TYPES = %w[
      nf_discount_mismatch nf_freight_mismatch settlement_amount_mismatch missing_settlement fee_rate_mismatch
    ].freeze
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

      current_totals = period_totals(orders_scope, period)
      prev_totals    = period_totals(prev_scope, previous_period(period))
      period_rows    = revenue_rows(orders_scope, granularity)
      data_quality   = build_data_quality(orders_scope)
      coupons        = build_coupons(orders_scope)
      regional_sales = build_regional_sales(orders_scope, current_totals)

      exclusions = build_non_revenue_exclusions(orders_in_period(period))

      {
        period:                   { from: period[:from].iso8601, to: period[:to].iso8601 },
        granularity:              granularity,
        kpis:                     build_kpis(current_totals, prev_totals, data_quality, coupons, regional_sales).merge(exclusions),
        overview_financial_coverage: build_overview_financial_coverage(current_totals, prev_totals),
        revenue_breakdown:        build_revenue_breakdown(period, current_totals, prev_totals),
        financial_composition:    build_financial_composition(current_totals, data_quality),
        revenue_timeline:         build_revenue_timeline(period_rows, granularity),
        sales_by_channel:         build_sales_by_channel(orders_scope, current_totals),
        regional_sales:           regional_sales,
        coupons:                  coupons,
        discount_ticket_summary:  build_discount_ticket_summary(orders_scope),
        product_discount_exposure: build_product_discount_exposure(orders_scope),
        revenue:                  build_revenue(orders_scope, period_rows, granularity, current_totals, prev_totals),
        financial:                build_financial(orders_scope, current_totals, prev_totals, data_quality, period, granularity),
        margin:                   build_margin(period_rows, granularity, current_totals, prev_totals, data_quality),
        orders:                   build_orders(orders_scope, granularity, current_totals, prev_totals),
        data_sources:             build_data_sources,
        data_quality:             data_quality,
        conflicts:                build_conflicts,
        reconciliation:           build_reconciliation(period),
        cart_abandonment:         build_cart_abandonment(period),
        freight_margin:           build_freight_margin(period),
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
        .not_canceled
        .revenue_countable
    end

    # Contrapartida de transparência do revenue_countable: os pedidos
    # unpaid/status_unknown ficam FORA de receita/pedidos/ticket, e a UI
    # mostra um selo "Exclui N pedidos não pagos/indeterminados (R$ X)" nos
    # cards afetados. Mesmo escopo período+canal dos KPIs, invertendo só o
    # filtro de status.
    def build_non_revenue_exclusions(scope)
      count, amount = scope
        .where(order_type: %w[sale refund])
        .where("LOWER(COALESCE(status, '')) IN (?)", Order::NON_REVENUE_STATUSES)
        .pick(Arel.sql("COUNT(*)"), Arel.sql("COALESCE(SUM(gross_value), 0)"))

      {
        non_revenue_excluded_count: count.to_i,
        non_revenue_excluded_amount: amount.to_f.round(2)
      }
    end

    def format_bucket(bucket, granularity)
      granularity == "hour" ? bucket.iso8601 : bucket.to_date.iso8601
    end

    def pct_change(current, previous)
      return nil if previous.nil? || previous.to_f.abs < 0.01
      ((current - previous) / previous.to_f * 100).round(2)
    end

    # Regra central de "receita efetiva" da Visão Geral: pedido TikTok com
    # demonstrativo sincronizado usa revenue_amount (já líquido de desconto
    # do vendedor + subsídio da plataforma); pedido TikTok ainda pendente
    # (backfill em andamento) NÃO entra no valor financeiro — fica de fora
    # do SUM (NULL), mas continua contável operacionalmente em COUNT(*). Os
    # demais canais preservam a fórmula histórica (gross_value - discount -
    # refund_amount), sem nenhuma mudança de comportamento pra Yampi.
    #
    # Centralizado aqui de propósito: todo widget monetário da Visão Geral
    # (kpis, revenue_breakdown, revenue_timeline, sales_by_channel,
    # regional_sales) deve reutilizar este helper em vez de reimplementar o
    # CASE. Exige que a scope já tenha `.joins(:channel)` (usa
    # channels.platform).
    def effective_revenue_sql
      "CASE " \
        "WHEN channels.platform = 'tiktok' AND orders.financial_synced_at IS NOT NULL THEN orders.revenue_amount " \
        "WHEN channels.platform = 'tiktok' THEN NULL " \
        "ELSE COALESCE(orders.gross_value, 0) - COALESCE(orders.discount, 0) - COALESCE(orders.refund_amount, 0) " \
      "END"
    end

    # Predicado companheiro de effective_revenue_sql: true quando o pedido
    # entra no valor financeiro acima, false quando é TikTok ainda pendente.
    # Usado em COUNT(*) FILTER pra contar "pedidos com financeiro
    # disponível" sem duplicar a condição em outra sintaxe.
    def financial_revenue_available_sql
      "NOT (channels.platform = 'tiktok' AND orders.financial_synced_at IS NULL)"
    end

    # Uma única query agregada por trás de effective_revenue e da contagem
    # de cobertura TikTok — reutilizada por period_totals (período atual e
    # anterior) e por qualquer outro agregado que precise só desses números.
    def effective_revenue_totals(scope)
      total, financial_count, tiktok_count, tiktok_synced_count = scope.joins(:channel).pick(
        Arel.sql("COALESCE(SUM(#{effective_revenue_sql}), 0)"),
        Arel.sql("COUNT(*) FILTER (WHERE #{financial_revenue_available_sql})"),
        Arel.sql("COUNT(*) FILTER (WHERE channels.platform = 'tiktok')"),
        Arel.sql("COUNT(*) FILTER (WHERE channels.platform = 'tiktok' AND orders.financial_synced_at IS NOT NULL)")
      ) || [ 0, 0, 0, 0 ]

      tiktok_orders_count = tiktok_count.to_i
      tiktok_synced_orders_count = tiktok_synced_count.to_i

      {
        effective_revenue: total.to_f.round(2),
        financial_orders_count: financial_count.to_i,
        tiktok_orders_count: tiktok_orders_count,
        tiktok_synced_orders_count: tiktok_synced_orders_count,
        tiktok_pending_orders_count: tiktok_orders_count - tiktok_synced_orders_count
      }
    end

    def tiktok_coverage_partial?(totals)
      totals[:tiktok_orders_count].to_i.positive? && totals[:tiktok_pending_orders_count].to_i.positive?
    end

    def tiktok_coverage_pct(totals)
      totals[:tiktok_orders_count].to_i.positive? ? (totals[:tiktok_synced_orders_count].to_f / totals[:tiktok_orders_count] * 100).round(2) : 100.0
    end

    def tiktok_delta_partial_note(current_totals, prev_totals)
      "Comparação parcial: cobertura TikTok atual #{tiktok_coverage_pct(current_totals)}%, " \
        "anterior #{tiktok_coverage_pct(prev_totals)}%."
    end

    def period_totals(scope, period)
      count, gross, refund, discount_amount, commission_amount, operational_cost = scope.pick(
        Arel.sql("COUNT(*)"),
        Arel.sql("COALESCE(SUM(gross_value), 0)"),
        Arel.sql("COALESCE(SUM(refund_amount), 0)"),
        Arel.sql("COALESCE(SUM(discount), 0)"),
        Arel.sql("COALESCE(SUM(commission), 0)"),
        Arel.sql("COALESCE(SUM(operational_cost), 0)")
      ) || [ 0, 0, 0, 0, 0, 0 ]

      gross_f = gross.to_f
      discounts_f = discount_amount.to_f
      refunds_f = refund.to_f
      net_f = gross_f - discounts_f - refunds_f
      product_cost_f = product_cost_for(scope)
      freight_f = freight_for(scope)
      taxes_f = taxes_for(scope)
      gateway_fees_f = gateway_fees_for(period)
      result_f = net_f - product_cost_f - freight_f - commission_amount.to_f - taxes_f - operational_cost.to_f - gateway_fees_f
      effective = effective_revenue_totals(scope)

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
        gateway_fees:     gateway_fees_f,
        result:           result_f,
        profit:           result_f,
        margin:           result_f,
        margin_pct:       net_f > 0 ? (result_f / net_f * 100) : 0,
        aov:              count > 0 ? (net_f / count) : 0,
        discounts_pct:    gross_f > 0 ? (discounts_f / gross_f * 100) : 0,
        # Campos aditivos usados pela Visão Geral (raio-x TikTok pendente) —
        # não substituem net/aov acima, que continuam alimentando a aba
        # Financeiro exatamente como antes.
        effective_revenue:          effective[:effective_revenue],
        financial_orders_count:     effective[:financial_orders_count],
        tiktok_orders_count:        effective[:tiktok_orders_count],
        tiktok_synced_orders_count: effective[:tiktok_synced_orders_count],
        tiktok_pending_orders_count: effective[:tiktok_pending_orders_count],
        effective_average_ticket:  effective[:financial_orders_count].positive? ? (effective[:effective_revenue] / effective[:financial_orders_count]).round(2) : nil
      }
    end

    def revenue_rows(scope, granularity)
      trunc = granularity == "hour" ? "hour" : "day"
      scope
        .joins(:channel)
        .group(Arel.sql("date_trunc('#{trunc}', orders.ordered_at)"))
        .order(Arel.sql("date_trunc('#{trunc}', orders.ordered_at)"))
        .pluck(
          Arel.sql("date_trunc('#{trunc}', orders.ordered_at)"),
          Arel.sql("COALESCE(SUM(orders.gross_value), 0)"),
          Arel.sql("COALESCE(SUM(orders.refund_amount), 0)"),
          Arel.sql("COALESCE(SUM(orders.discount), 0)"),
          Arel.sql("COUNT(*)"),
          Arel.sql("COALESCE(SUM(#{effective_revenue_sql}), 0)"),
          Arel.sql("COUNT(*) FILTER (WHERE #{financial_revenue_available_sql})"),
          Arel.sql("COUNT(*) FILTER (WHERE channels.platform = 'tiktok' AND orders.financial_synced_at IS NULL)")
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

    def build_financial(scope, current_totals, prev_totals, data_quality, period, granularity)
      product_cost = current_totals[:product_cost].round(2)
      financial_available = data_quality[:financial_status] == "complete"
      tiktok_breakdown = build_tiktok_financial_breakdown(scope, financial_available: financial_available)

      {
        product_cost: product_cost,
        freight: current_totals[:freight].round(2),
        taxes: current_totals[:taxes].round(2),
        discounts: current_totals[:discounts].round(2),
        commissions: current_totals[:commissions].round(2),
        operational_cost: current_totals[:operational_cost].round(2),
        gateway_fees: current_totals[:gateway_fees].round(2),
        refunds: current_totals[:refunds].round(2),
        profit: financial_available ? current_totals[:profit].round(2) : nil,
        margin: financial_available ? current_totals[:margin].round(2) : nil,
        margin_pct: financial_available ? current_totals[:margin_pct].round(2) : nil,
        profit_available: financial_available,
        margin_available: financial_available,
        unavailable_reason: financial_available ? nil : data_quality[:financial_status_reason],
        product_cost_vs_previous_pct: pct_change(product_cost, prev_totals[:product_cost]),
        profit_vs_previous_pct: financial_available ? pct_change(current_totals[:profit], prev_totals[:profit]) : nil,
        # Estatística isolada, independente do filtro de canal do dashboard:
        # sempre taxa Pagar.me (todo o histórico é atribuído ao canal Yampi
        # na origem) dividida por pedidos do canal Yampi no período — nunca
        # por pedido individual, porque o vínculo pedido↔pagamento da
        # Pagar.me não é confiável (código de pedido da API não bate com
        # nenhum campo salvo em Order). Não usar em listas/tabelas de
        # pedidos, só como card/stat agregado.
        gateway_fee_avg_per_order: gateway_fee_avg_per_order(period),
        gateway_fee_avg_per_order_available: payment_reconciliation_source_configured?,
        tiktok_financial_breakdown: tiktok_breakdown,
        tiktok_coverage: build_tiktok_coverage(tiktok_breakdown),
        tiktok_daily_series: build_tiktok_daily_series(scope, granularity),
        consolidated: build_financial_consolidated(scope, period, current_totals, tiktok_breakdown, financial_available)
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
      revenue_delta_partial = tiktok_coverage_partial?(current_totals) || tiktok_coverage_partial?(prev_totals)
      current_ticket = current_totals[:effective_average_ticket]
      prev_ticket = prev_totals[:effective_average_ticket]

      {
        gross_revenue: current_totals[:gross].round(2),
        net_revenue: current_totals[:effective_revenue],
        net_revenue_vs_previous_pct: pct_change(current_totals[:effective_revenue], prev_totals[:effective_revenue]),
        # Comparação parcial (seção 10 do raio-x TikTok pendente): quando o
        # período atual ou o anterior tem TikTok com backfill incompleto, o
        # delta acima continua calculado (nunca escondido), mas vem
        # acompanhado desse aviso pro frontend não apresentá-lo como
        # definitivo.
        net_revenue_delta_partial: revenue_delta_partial,
        net_revenue_delta_note: revenue_delta_partial ? tiktok_delta_partial_note(current_totals, prev_totals) : nil,
        orders_count: current_totals[:count],
        orders_vs_previous_pct: pct_change(current_totals[:count], prev_totals[:count]),
        # Pedidos com receita financeira disponível vs. pendentes de
        # sincronização — total operacional (orders_count) nunca muda por
        # causa da cobertura TikTok, só esses contadores auxiliares.
        financial_orders_count: current_totals[:financial_orders_count],
        tiktok_orders_count: current_totals[:tiktok_orders_count],
        tiktok_synced_orders_count: current_totals[:tiktok_synced_orders_count],
        tiktok_pending_orders_count: current_totals[:tiktok_pending_orders_count],
        # Ticket médio financeiro: receita efetiva / pedidos com receita
        # disponível — nunca o total operacional de pedidos TikTok, senão o
        # ticket cai artificialmente enquanto o backfill roda. nil (não
        # zero) quando não há nenhum pedido com receita disponível.
        average_ticket: current_ticket,
        average_ticket_available: !current_ticket.nil?,
        average_ticket_vs_previous_pct: (current_ticket && prev_ticket) ? pct_change(current_ticket, prev_ticket) : nil,
        average_ticket_delta_partial: revenue_delta_partial,
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

    # Banner "Cobertura financeira TikTok" da Visão Geral (seção 9 do
    # raio-x TikTok pendente) — derivado só dos pedidos já contados em
    # period_totals, sem consultar status de job/Sidekiq. current/previous
    # _partial alimentam o aviso de comparação parcial dos deltas (seção
    # 10): o frontend esconde o banner quando tiktok_orders_count é zero
    # (filtro excluiu TikTok) ou quando a cobertura chega a 100%.
    def build_overview_financial_coverage(current_totals, prev_totals)
      {
        total_financial_orders: current_totals[:financial_orders_count],
        tiktok_orders_count: current_totals[:tiktok_orders_count],
        tiktok_synced_orders_count: current_totals[:tiktok_synced_orders_count],
        tiktok_pending_orders_count: current_totals[:tiktok_pending_orders_count],
        tiktok_coverage_percentage: tiktok_coverage_pct(current_totals),
        current_period_partial: tiktok_coverage_partial?(current_totals),
        previous_period_partial: tiktok_coverage_partial?(prev_totals)
      }
    end

    # Breakdown contábil do card de receita da Visão Geral. A bruta daqui
    # INCLUI os pedidos cancelados do período (que ficam fora de todos os
    # outros agregados via financial_orders) para que a conta feche linha a
    # linha: bruta - descontos - cancelados/devolvidos - frete/imposto =
    # líquida. Essa líquida desconta frete e imposto, diferente do :net
    # histórico (gross - discounts - refunds) que alimenta séries, AOV e
    # share por canal.
    def build_revenue_breakdown(period, current_totals, prev_totals)
      current  = revenue_breakdown_values(current_totals, canceled_amount_for(period))
      previous = revenue_breakdown_values(prev_totals, canceled_amount_for(previous_period(period)))

      current.merge(
        net_vs_previous_pct: pct_change(current[:net_revenue], previous[:net_revenue]),
        # TikTok pendente (backfill em andamento) fica fora do net_revenue
        # acima — esses dois campos deixam essa cobertura parcial visível
        # no próprio card, em vez de um número silenciosamente incompleto.
        tiktok_pending_orders_count: current_totals[:tiktok_pending_orders_count],
        financial_coverage_partial: tiktok_coverage_partial?(current_totals)
      )
    end

    # freight e taxes vão separados: tax_amount está 0.0 em 100% dos pedidos
    # em produção (sem fonte de imposto), então a UI rotula a linha só como
    # "Frete" enquanto taxes for zero — e volta a "Frete e imposto" sozinha
    # quando uma fonte real de imposto passar a popular tax_amount.
    #
    # net_revenue usa effective_revenue (não totals[:net]): pedido TikTok
    # sincronizado entra por revenue_amount, pendente fica de fora — freight
    # e taxes continuam os mesmos de sempre (colunas legadas, tipicamente
    # zeradas pra TikTok, nunca fee_and_tax_amount/settlement_amount).
    def revenue_breakdown_values(totals, canceled_amount)
      freight_and_taxes = totals[:freight] + totals[:taxes]

      {
        gross_revenue:             (totals[:gross] + canceled_amount).round(2),
        discounts:                 totals[:discounts].round(2),
        cancellations_and_refunds: (canceled_amount + totals[:refunds]).round(2),
        freight:                   totals[:freight].round(2),
        taxes:                     totals[:taxes].round(2),
        freight_and_taxes:         freight_and_taxes.round(2),
        net_revenue:               (totals[:effective_revenue] - freight_and_taxes).round(2)
      }
    end

    def canceled_amount_for(period)
      orders_in_period(period)
        .where(order_type: %w[sale refund])
        .canceled
        .sum(:gross_value)
        .to_f
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
        gateway_fees: composition_line(
          payment_reconciliation_source_configured? ? current_totals[:gateway_fees] : nil,
          payment_reconciliation_source_configured? ? "available" : "not_configured",
          payment_reconciliation_source_configured? ?
            "Soma de fee_amount dos FinancialSettlementItem do Pagar.me (inclui antecipação quando houver). Fonte única — não soma com FinancialReceivable, que reflete o mesmo payable." :
            "Pagar.me não está configurado como fonte de conciliação de pagamentos (data_source_configs payment_reconciliation)."
        ),
        result: composition_line(
          result_available ? current_totals[:result] : nil,
          result_available ? "available" : "incomplete",
          "Receita líquida - CMV - frete - comissões - impostos - custos operacionais - taxa de gateway.",
          result_available ? nil : incomplete_reason
        ),
        result_available: result_available,
        result_unavailable_reason: result_available ? nil : incomplete_reason
      }
    end

    # net aqui é a receita EFETIVA do dia (effective_revenue_sql), não mais
    # gross-discount-refund puro — pedido TikTok sincronizado entra por
    # revenue_amount, pendente fica de fora do valor (mas contável em
    # orders_count). average_ticket divide pelos pedidos com financeiro
    # disponível, nil (não 0) quando nenhum pedido do dia tem receita.
    def build_revenue_timeline(rows, granularity)
      rows.map do |bucket, gross, refund, discount, orders_count, effective_revenue, financial_orders_count, tiktok_pending_count|
        gross_f = gross.to_f
        discounts_f = discount.to_f
        refunds_f = refund.to_f
        orders_count_i = orders_count.to_i
        effective_revenue_f = effective_revenue.to_f.round(2)
        financial_orders_count_i = financial_orders_count.to_i

        {
          date: format_bucket(bucket, granularity),
          gross: gross_f.round(2),
          discounts: discounts_f.round(2),
          refunds: refunds_f.round(2),
          net: effective_revenue_f,
          orders_count: orders_count_i,
          financial_orders_count: financial_orders_count_i,
          tiktok_pending_orders_count: tiktok_pending_count.to_i,
          average_ticket: financial_orders_count_i.positive? ? (effective_revenue_f / financial_orders_count_i).round(2) : nil
        }
      end
    end

    # net_revenue por canal usa effective_revenue_sql: TikTok sincronizado
    # entra por revenue_amount, nunca gross_value (pendente fica fora da
    # soma). tiktok_coverage_percentage só vem preenchido na linha do canal
    # TikTok — usado pelo frontend pra rotular a barra como parcial.
    def build_sales_by_channel(scope, current_totals)
      rows = scope
        .joins(:channel)
        .group("channels.id", "channels.name", "channels.platform")
        .pluck(
          Arel.sql("channels.name"),
          Arel.sql("channels.platform"),
          Arel.sql("COUNT(*)"),
          Arel.sql("COALESCE(SUM(orders.gross_value), 0)"),
          Arel.sql("COALESCE(SUM(orders.discount), 0)"),
          Arel.sql("COALESCE(SUM(orders.refund_amount), 0)"),
          Arel.sql("COALESCE(SUM(#{effective_revenue_sql}), 0)"),
          Arel.sql("COUNT(*) FILTER (WHERE #{financial_revenue_available_sql})"),
          Arel.sql("COUNT(*) FILTER (WHERE channels.platform = 'tiktok' AND orders.financial_synced_at IS NOT NULL)")
        )

      total_effective_revenue = current_totals[:effective_revenue]
      rows.filter_map do |name, platform, count, gross, discount, refund, effective_revenue, financial_orders_count, tiktok_synced_count|
        count_i = count.to_i
        next if count_i.zero?

        gross_f = gross.to_f
        discount_f = discount.to_f
        refund_f = refund.to_f
        effective_revenue_f = effective_revenue.to_f.round(2)
        financial_orders_count_i = financial_orders_count.to_i
        tiktok_coverage = platform == "tiktok" ? (tiktok_synced_count.to_f / count_i * 100).round(2) : nil

        {
          channel: name,
          net_revenue: effective_revenue_f,
          gross_revenue: gross_f.round(2),
          discounts: discount_f.round(2),
          refunds: refund_f.round(2),
          orders_count: count_i,
          financial_orders_count: financial_orders_count_i,
          average_ticket: financial_orders_count_i.positive? ? (effective_revenue_f / financial_orders_count_i).round(2) : nil,
          share_percentage: total_effective_revenue.positive? ? (effective_revenue_f / total_effective_revenue * 100).round(2) : 0,
          tiktok_coverage_percentage: tiktok_coverage
        }
      end.sort_by { |row| -row[:net_revenue] }
    end

    # Quantidade de pedidos por UF continua 100% operacional (nunca some do
    # mapa por falta de financeiro). net_revenue usa effective_revenue_sql —
    # TikTok pendente não soma valor no estado, mas
    # tiktok_pending_orders_count torna essa cobertura parcial visível.
    def build_regional_sales(scope, current_totals)
      rows = scope
        .joins(:channel)
        .group(:state)
        .pluck(
          :state,
          Arel.sql("COUNT(*)"),
          Arel.sql("COALESCE(SUM(orders.gross_value), 0)"),
          Arel.sql("COALESCE(SUM(#{effective_revenue_sql}), 0)"),
          Arel.sql("COUNT(*) FILTER (WHERE channels.platform = 'tiktok' AND orders.financial_synced_at IS NULL)")
        )

      aggregate = Hash.new { |hash, uf| hash[uf] = { orders_count: 0, net_revenue: 0.0, gross_revenue: 0.0, tiktok_pending_orders_count: 0 } }
      unknown_orders = 0

      rows.each do |raw_state, count, gross, effective_revenue, tiktok_pending|
        uf = normalize_state(raw_state)
        if uf.blank?
          unknown_orders += count.to_i
          next
        end

        aggregate[uf][:orders_count] += count.to_i
        aggregate[uf][:net_revenue] += effective_revenue.to_f
        aggregate[uf][:gross_revenue] += gross.to_f
        aggregate[uf][:tiktok_pending_orders_count] += tiktok_pending.to_i
      end

      states = BRAZIL_STATES.map do |uf, name|
        values = aggregate[uf]
        {
          state: uf,
          name: name,
          orders_count: values[:orders_count],
          net_revenue: values[:net_revenue].round(2),
          gross_revenue: values[:gross_revenue].round(2),
          share_percentage: current_totals[:count].positive? ? (values[:orders_count].to_f / current_totals[:count] * 100).round(2) : 0,
          tiktok_pending_orders_count: values[:tiktok_pending_orders_count],
          financial_coverage_partial: values[:tiktok_pending_orders_count].positive?
        }
      end

      ranked = states.select { |state| state[:orders_count].positive? }.sort_by { |state| [ -state[:orders_count], -state[:net_revenue] ] }

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
      channel_scope = scope.joins(:channel)
      coupon_scope = channel_scope.where(coupon_predicate)
      uncoded_discount_scope = channel_scope
        .where(uncoded_discount_predicate)
        .where.not(channels: { platform: "tiktok" })
      shipping_subsidy_scope = channel_scope.where(shipping_subsidy_predicate)
      incentive_scope = channel_scope.where(
        "(#{coupon_predicate}) OR ((#{uncoded_discount_predicate}) AND channels.platform <> 'tiktok') OR (#{shipping_subsidy_predicate})"
      )
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
      end.sort_by { |row| [ -row[:discount_total], -row[:orders_count] ] }.first(10)

      # Blocos por plataforma: Yampi tem cupom identificado (coupon_code);
      # TikTok expõe desconto de vendedor, subsídio da plataforma e os totais
      # financeiros somente quando o demonstrativo foi sincronizado.
      # `available` segue o filtro de canal do dashboard (channel_ids), não
      # a presença de dados — com filtro só-TikTok o card Yampi some em vez
      # de aparecer vazio.
      yampi_coupon_scope = coupon_scope.joins(:channel).where(channels: { platform: "yampi" })
      yampi_rows = yampi_coupon_scope
        .group(Arel.sql("UPPER(TRIM(coupon_code))"))
        .pluck(
          Arel.sql("UPPER(TRIM(coupon_code))"),
          Arel.sql("COUNT(*)"),
          Arel.sql("COALESCE(SUM(#{coupon_value_sql}), 0)")
        )
      yampi_top_coupons = yampi_rows.map do |code, count, discount|
        { code: code, orders_count: count.to_i, discount_total: discount.to_f.round(2) }
      end.sort_by { |row| [ -row[:discount_total], -row[:orders_count] ] }.first(10)

      tiktok_scope = scope.joins(:channel).where(channels: { platform: "tiktok" })
      discount_breakdown_yampi = {
        available: filtered_platforms.include?("yampi"),
        orders_count: yampi_coupon_scope.count,
        discount_total: yampi_coupon_scope.sum(Arel.sql(coupon_value_sql)).to_f.round(2),
        top_coupons: yampi_top_coupons
      }
      discount_breakdown_tiktok = {
        available: filtered_platforms.include?("tiktok"),
        orders_count: tiktok_scope.count,
        financial_synced_orders_count: tiktok_financial_synced_scope(tiktok_scope).count,
        financial_coverage_percentage: tiktok_coverage_percentage(tiktok_scope),
        reference_price_total: tiktok_scope.sum(:gross_value).to_f.round(2),
        effective_revenue_total: tiktok_effective_revenue_total(tiktok_scope),
        buyer_paid_product_total: tiktok_buyer_paid_product_total(tiktok_scope),
        seller_discount_total: tiktok_scope.sum(Arel.sql(tiktok_seller_discount_sql)).to_f.round(2),
        seller_discount_orders_count: tiktok_scope.where(Arel.sql("(#{tiktok_seller_discount_sql}) > 0")).count,
        platform_subsidy_total: tiktok_scope.sum(Arel.sql(tiktok_platform_subsidy_sql)).to_f.round(2),
        platform_subsidy_orders_count: tiktok_scope.where(Arel.sql("(#{tiktok_platform_subsidy_sql}) > 0")).count,
        seller_shipping_subsidy_total: tiktok_scope.sum(Arel.sql("GREATEST(COALESCE(orders.shipping_fee_seller_discount, 0), 0)")).to_f.round(2),
        platform_shipping_subsidy_total: tiktok_scope.sum(Arel.sql("GREATEST(COALESCE(orders.shipping_fee_platform_discount, 0), 0)")).to_f.round(2),
        discount_total: tiktok_scope.sum(Arel.sql(tiktok_seller_discount_sql)).to_f.round(2)
      }

      commercial_discount_total = uncoded_discount_total
      commercial_discount_orders_count = uncoded_discount_orders_count

      # "Descontos" (display_discount_total) representa só valor bancado
      # pelo VENDEDOR — inclui o desconto vendedor TikTok (produto + frete),
      # nunca o subsídio pago pela plataforma. Subsídio TikTok vira um total
      # separado (platform_incentive_total), nunca somado aqui como se
      # fosse prejuízo do vendedor.
      tiktok_vendor_funded_total = (
        discount_breakdown_tiktok[:seller_discount_total] + discount_breakdown_tiktok[:seller_shipping_subsidy_total]
      ).round(2)
      tiktok_platform_incentive_total = (
        discount_breakdown_tiktok[:platform_subsidy_total] + discount_breakdown_tiktok[:platform_shipping_subsidy_total]
      ).round(2)
      discount_breakdown_tiktok = discount_breakdown_tiktok.merge(
        vendor_funded_total: tiktok_vendor_funded_total,
        platform_incentive_total: tiktok_platform_incentive_total
      )

      display_discount_total = total_discount + commercial_discount_total + shipping_subsidy_total + tiktok_vendor_funded_total
      display_orders_count = incentive_scope.count + discount_breakdown_tiktok[:seller_discount_orders_count]
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
        # Incentivos bancados PELA PLATAFORMA (subsídio de produto + frete
        # TikTok) — nunca somado a display_discount_total. Renomeie o card
        # da Visão Geral para "Descontos e incentivos" quando os dois
        # totais precisarem aparecer lado a lado.
        platform_incentive_total: tiktok_platform_incentive_total,
        platform_incentive_orders_count: discount_breakdown_tiktok[:platform_subsidy_orders_count],
        usage_percentage: total_orders.positive? ? (display_orders_count.to_f / total_orders * 100).round(2) : 0,
        breakdown: breakdown,
        top_coupons: top_coupons,
        discount_breakdown_yampi: discount_breakdown_yampi,
        discount_breakdown_tiktok: discount_breakdown_tiktok,
        by_product: build_discount_by_product(scope)
      }
    end

    # available: financial_available reflete a mesma flag de cobertura de
    # custo (data_quality[:financial_status]) usada por profit/margin no
    # resto de `financial:` — sem custo completo, lucro/margem real TikTok
    # também ficam indisponíveis (não só o Yampi), pra não sugerir precisão
    # que os dados não sustentam.
    def build_tiktok_financial_breakdown(scope, financial_available: true)
      return empty_tiktok_financial_breakdown unless tiktok_financial_fields_available?

      tiktok_scope = scope.joins(:channel).where(channels: { platform: "tiktok" })
      synced_scope = tiktok_financial_synced_scope(tiktok_scope)
      orders_count = tiktok_scope.count
      synced_orders_count = synced_scope.count

      revenue_total, settlement_total, fee_total, platform_commission_total, affiliate_commission_total,
        item_fee_total, service_fee_total, shipping_cost_total, product_cost_total,
        platform_commission_orders, affiliate_commission_orders, item_fee_orders,
        service_fee_orders, shipping_cost_orders = synced_scope.pick(
          Arel.sql("COALESCE(SUM(revenue_amount), 0)"),
          Arel.sql("COALESCE(SUM(settlement_amount), 0)"),
          Arel.sql("COALESCE(SUM(fee_and_tax_amount), 0)"),
          Arel.sql("COALESCE(SUM(platform_commission_amount), 0)"),
          Arel.sql("COALESCE(SUM(affiliate_commission_amount), 0)"),
          Arel.sql("COALESCE(SUM(item_fee_amount), 0)"),
          Arel.sql("COALESCE(SUM(service_fee_amount), 0)"),
          Arel.sql("COALESCE(SUM(shipping_cost_amount), 0)"),
          Arel.sql("COALESCE(SUM(cost_price), 0)"),
          Arel.sql("COUNT(*) FILTER (WHERE COALESCE(platform_commission_amount, 0) > 0)"),
          Arel.sql("COUNT(*) FILTER (WHERE COALESCE(affiliate_commission_amount, 0) > 0)"),
          Arel.sql("COUNT(*) FILTER (WHERE COALESCE(item_fee_amount, 0) > 0)"),
          Arel.sql("COUNT(*) FILTER (WHERE COALESCE(service_fee_amount, 0) > 0)"),
          Arel.sql("COUNT(*) FILTER (WHERE COALESCE(shipping_cost_amount, 0) > 0)")
        ) || Array.new(14, 0)

      revenue_f = revenue_total.to_f.round(2)
      settlement_f = settlement_total.to_f.round(2)
      fee_f = fee_total.to_f.round(2)
      platform_commission_f = platform_commission_total.to_f.round(2)
      affiliate_commission_f = affiliate_commission_total.to_f.round(2)
      item_fee_f = item_fee_total.to_f.round(2)
      service_fee_f = service_fee_total.to_f.round(2)
      shipping_cost_f = shipping_cost_total.to_f.round(2)
      product_cost_f = product_cost_total.to_f.round(2)
      other_fees_f = [ fee_f - platform_commission_f - affiliate_commission_f - item_fee_f - service_fee_f, 0 ].max.round(2)
      other_fees_orders = synced_scope.where(Arel.sql("(#{tiktok_other_fees_sql}) > 0")).count

      # Regra financeira TikTok já existente (Order#calculate_margin):
      # lucro real = settlement_amount - custo do produto; margem real =
      # lucro real / revenue_amount. Recalculado aqui via SUM agregado (não
      # via média de orders.margin_pct por pedido, que é clampado e não
      # pondera por valor) para bater exatamente com a soma dos pedidos.
      real_profit = (settlement_f - product_cost_f).round(2)
      real_margin_pct = revenue_f.positive? ? (real_profit / revenue_f * 100).round(2) : nil

      # Outros ajustes: diferença entre o que a composição de taxas explica
      # (receita - taxas - frete) e o settlement_amount realmente recebido.
      # Nunca escondido dentro de outra categoria — ver gadget de
      # reconciliação. Cobre estornos parciais, chargebacks e ajustes que a
      # TikTok não detalha nos campos de taxa.
      explained_settlement = (revenue_f - fee_f - shipping_cost_f).round(2)
      other_adjustments = (settlement_f - explained_settlement).round(2)

      {
        available: filtered_platforms.include?("tiktok"),
        orders_count: orders_count,
        synced_orders_count: synced_orders_count,
        coverage_percentage: orders_count.positive? ? (synced_orders_count.to_f / orders_count * 100).round(2) : 0,
        revenue_amount_total: revenue_f,
        settlement_amount_total: settlement_f,
        fee_and_tax_amount_total: fee_f,
        platform_commission_total: platform_commission_f,
        affiliate_commission_total: affiliate_commission_f,
        item_fee_total: item_fee_f,
        service_fee_total: service_fee_f,
        shipping_cost_total: shipping_cost_f,
        other_fees_total: other_fees_f,
        product_cost_total: product_cost_f,
        real_profit_total: financial_available ? real_profit : nil,
        real_margin_pct: financial_available ? real_margin_pct : nil,
        real_profit_available: financial_available,
        fee_composition: [
          fee_composition_line("platform_commission", "Comissão da plataforma", platform_commission_f, platform_commission_orders, revenue_f),
          fee_composition_line("affiliate_commission", "Comissão de afiliados", affiliate_commission_f, affiliate_commission_orders, revenue_f),
          fee_composition_line("item_fee", "Taxa por item", item_fee_f, item_fee_orders, revenue_f),
          fee_composition_line("service_fee", "Taxa de serviço", service_fee_f, service_fee_orders, revenue_f),
          fee_composition_line("shipping_cost", "Frete líquido", shipping_cost_f, shipping_cost_orders, revenue_f),
          fee_composition_line("other_fees", "Outras taxas", other_fees_f, other_fees_orders, revenue_f)
        ],
        reconciliation: [
          { key: "effective_revenue", label: "Receita efetiva", amount: revenue_f },
          { key: "platform_commission", label: "Comissão da plataforma", amount: -platform_commission_f },
          { key: "affiliate_commission", label: "Comissão de afiliados", amount: -affiliate_commission_f },
          { key: "item_fee", label: "Taxa por item", amount: -item_fee_f },
          { key: "service_fee", label: "Taxa de serviço", amount: -service_fee_f },
          { key: "other_fees", label: "Outras taxas", amount: -other_fees_f },
          { key: "shipping_cost", label: "Custo líquido de frete", amount: -shipping_cost_f },
          { key: "other_adjustments", label: "Outros ajustes", amount: other_adjustments },
          { key: "settlement_amount", label: "Valor liquidado", amount: settlement_f, subtotal: true },
          { key: "product_cost", label: "Custo dos produtos", amount: -product_cost_f },
          { key: "real_profit", label: "Lucro real", amount: real_profit, subtotal: true }
        ]
      }
    end

    def fee_composition_line(key, label, amount, orders_count, revenue_total)
      {
        key: key,
        label: label,
        amount: amount,
        orders_count: orders_count,
        percentage_of_revenue: revenue_total.positive? ? (amount / revenue_total * 100).round(2) : nil
      }
    end

    # Indicador "Cobertura financeira TikTok" (seção 6 do raio-x): reaproveita
    # os totais já computados por build_tiktok_financial_breakdown — nenhuma
    # query adicional. status é só um rótulo derivado da cobertura, nunca
    # consulta o estado de um job/cron.
    def build_tiktok_coverage(breakdown)
      pending = breakdown[:orders_count] - breakdown[:synced_orders_count]

      {
        available: breakdown[:available],
        orders_count: breakdown[:orders_count],
        synced_orders_count: breakdown[:synced_orders_count],
        pending_orders_count: pending,
        coverage_percentage: breakdown[:coverage_percentage],
        status: tiktok_coverage_status(breakdown[:coverage_percentage], pending)
      }
    end

    def tiktok_coverage_status(coverage_percentage, pending_count)
      return "Nenhum pedido TikTok no período." if coverage_percentage.zero? && pending_count.zero?
      return "Dados completos para o período." if coverage_percentage >= 100.0

      "Dados históricos ainda em processamento."
    end

    # Série diária para os gráficos "Resultado financeiro diário" e "Margem
    # real por dia" — só pedidos TikTok com demonstrativo sincronizado
    # (financial_synced_at) entram, então dias com cobertura parcial mostram
    # menos volume, nunca um valor projetado/fictício.
    def build_tiktok_daily_series(scope, granularity)
      return [] unless tiktok_financial_fields_available?

      tiktok_scope = scope.joins(:channel).where(channels: { platform: "tiktok" })
      synced_scope = tiktok_financial_synced_scope(tiktok_scope)
      trunc = granularity == "hour" ? "hour" : "day"

      rows = synced_scope
        .group(Arel.sql("date_trunc('#{trunc}', ordered_at)"))
        .order(Arel.sql("date_trunc('#{trunc}', ordered_at)"))
        .pluck(
          Arel.sql("date_trunc('#{trunc}', ordered_at)"),
          Arel.sql("COALESCE(SUM(revenue_amount), 0)"),
          Arel.sql("COALESCE(SUM(settlement_amount), 0)"),
          Arel.sql("COALESCE(SUM(cost_price), 0)"),
          Arel.sql("COUNT(*)")
        )

      rows.map do |bucket, revenue, settlement, cost, orders_count|
        revenue_f = revenue.to_f
        settlement_f = settlement.to_f
        profit_f = (settlement_f - cost.to_f).round(2)

        {
          date: format_bucket(bucket, granularity),
          revenue_amount: revenue_f.round(2),
          settlement_amount: settlement_f.round(2),
          profit: profit_f,
          margin_pct: revenue_f.positive? ? (profit_f / revenue_f * 100).round(2) : nil,
          orders_count: orders_count.to_i
        }
      end
    end

    # Card executivo "Consolidado": soma Yampi (recebíveis Pagar.me já
    # existentes) e TikTok (settlement/lucro já calculados acima) sem
    # misturar as fórmulas — cada plataforma mantém sua própria regra
    # (ver seção 13 do raio-x) e só os TOTAIS finais são somados.
    def build_financial_consolidated(scope, period, current_totals, tiktok_breakdown, financial_available)
      non_tiktok_scope = scope.joins(:channel).where.not(channels: { platform: "tiktok" })
      yampi_totals = period_totals(non_tiktok_scope, period)
      yampi_receivables = yampi_receivables_totals(period)

      tiktok_revenue = tiktok_breakdown[:revenue_amount_total]
      tiktok_received = tiktok_breakdown[:settlement_amount_total]
      tiktok_fees = tiktok_breakdown[:fee_and_tax_amount_total]
      tiktok_cost = tiktok_breakdown[:product_cost_total]
      tiktok_profit = tiktok_breakdown[:real_profit_total]

      effective_revenue = (yampi_totals[:net] + tiktok_revenue).round(2)
      received_amount = (yampi_receivables[:received] + tiktok_received).round(2)
      product_cost_total = (yampi_totals[:product_cost] + tiktok_cost).round(2)
      fees_total = (yampi_totals[:gateway_fees] + tiktok_fees).round(2)
      real_profit = financial_available ? (yampi_totals[:result] + tiktok_profit.to_f).round(2) : nil
      real_margin_pct = financial_available && effective_revenue.positive? ? (real_profit / effective_revenue * 100).round(2) : nil

      {
        effective_revenue: effective_revenue,
        received_amount: received_amount,
        pending_amount: yampi_receivables[:pending],
        fees_total: fees_total,
        product_cost_total: product_cost_total,
        real_profit: real_profit,
        real_margin_pct: real_margin_pct,
        real_profit_available: financial_available,
        orders_count: current_totals[:count],
        yampi: {
          effective_revenue: yampi_totals[:net].round(2),
          received_amount: yampi_receivables[:received],
          pending_amount: yampi_receivables[:pending],
          fees_total: yampi_totals[:gateway_fees].round(2),
          product_cost: yampi_totals[:product_cost].round(2),
          real_profit: financial_available ? yampi_totals[:result].round(2) : nil,
          orders_count: yampi_totals[:count]
        },
        tiktok: {
          effective_revenue: tiktok_revenue,
          received_amount: tiktok_received,
          fees_total: tiktok_fees,
          product_cost: tiktok_cost,
          real_profit: financial_available ? tiktok_profit : nil,
          real_margin_pct: financial_available ? tiktok_breakdown[:real_margin_pct] : nil,
          orders_count: tiktok_breakdown[:orders_count],
          synced_orders_count: tiktok_breakdown[:synced_orders_count],
          coverage_percentage: tiktok_breakdown[:coverage_percentage]
        }
      }
    end

    # Recebido/previsto da Yampi por payment_date (não ordered_at) — mesmo
    # campo já usado pelo cash flow existente de /dashboard/financial —,
    # mas filtrado pelo período PRINCIPAL do dashboard (from/to), pra manter
    # um único filtro de período na aba Financeiro (seção 1 do raio-x).
    def yampi_receivables_totals(period)
      return { received: 0.0, pending: 0.0 } unless payment_reconciliation_source_configured?

      scope = tenant.financial_receivables
        .joins(:financial_source)
        .where(financial_sources: { provider: "pagarme" })
        .where(payment_date: period[:from]..period[:to])

      received, pending = scope.pick(
        Arel.sql("COALESCE(SUM(financial_receivables.net_amount) FILTER (WHERE financial_receivables.status = 'paid'), 0)"),
        Arel.sql("COALESCE(SUM(financial_receivables.net_amount) FILTER (WHERE financial_receivables.status != 'paid'), 0)")
      ) || [ 0, 0 ]

      { received: received.to_f.round(2), pending: pending.to_f.round(2) }
    end

    def tiktok_financial_synced_scope(scope)
      return scope.none unless tiktok_financial_fields_available?

      scope.where.not(financial_synced_at: nil)
    end

    def tiktok_coverage_percentage(scope)
      orders_count = scope.count
      synced_count = tiktok_financial_synced_scope(scope).count
      orders_count.positive? ? (synced_count.to_f / orders_count * 100).round(2) : 0
    end

    def tiktok_buyer_paid_product_total(scope)
      synced_scope = tiktok_financial_synced_scope(scope)
      effective_revenue = synced_scope.sum(:revenue_amount).to_f
      platform_subsidy = synced_scope.sum(Arel.sql(tiktok_platform_subsidy_sql)).to_f
      (effective_revenue - platform_subsidy).round(2)
    end

    def tiktok_effective_revenue_total(scope)
      return 0.0 unless tiktok_financial_fields_available?

      tiktok_financial_synced_scope(scope).sum(:revenue_amount).to_f.round(2)
    end

    def tiktok_seller_discount_sql
      return "GREATEST(COALESCE(orders.seller_discount, 0), 0)" unless tiktok_financial_fields_available?

      "CASE WHEN COALESCE(orders.seller_discount, 0) > 0 " \
        "THEN COALESCE(orders.seller_discount, 0) " \
        "WHEN orders.financial_synced_at IS NOT NULL " \
        "THEN GREATEST(COALESCE(orders.gross_value, 0) - COALESCE(orders.revenue_amount, 0), 0) " \
        "ELSE 0 END"
    end

    def tiktok_platform_subsidy_sql
      return "GREATEST(COALESCE(orders.platform_discount, 0), 0)" unless tiktok_financial_fields_available?

      "CASE WHEN COALESCE(orders.platform_discount, 0) > 0 " \
        "THEN COALESCE(orders.platform_discount, 0) " \
        "WHEN orders.financial_synced_at IS NOT NULL " \
        "THEN GREATEST(COALESCE(orders.discount, 0) - (#{tiktok_seller_discount_sql}), 0) " \
        "ELSE 0 END"
    end

    def tiktok_other_fees_sql
      "GREATEST(COALESCE(orders.fee_and_tax_amount, 0) " \
        "- COALESCE(orders.platform_commission_amount, 0) " \
        "- COALESCE(orders.affiliate_commission_amount, 0) " \
        "- COALESCE(orders.item_fee_amount, 0) " \
        "- COALESCE(orders.service_fee_amount, 0), 0)"
    end

    def tiktok_financial_fields_available?
      @tiktok_financial_fields_available ||= %w[
        financial_synced_at revenue_amount settlement_amount fee_and_tax_amount
        shipping_cost_amount platform_commission_amount affiliate_commission_amount
        item_fee_amount service_fee_amount
      ].all? { |column| Order.column_names.include?(column) }
    end

    def empty_tiktok_financial_breakdown
      {
        available: false,
        orders_count: 0,
        synced_orders_count: 0,
        coverage_percentage: 0.0,
        revenue_amount_total: 0.0,
        settlement_amount_total: 0.0,
        fee_and_tax_amount_total: 0.0,
        platform_commission_total: 0.0,
        affiliate_commission_total: 0.0,
        item_fee_total: 0.0,
        service_fee_total: 0.0,
        shipping_cost_total: 0.0,
        other_fees_total: 0.0,
        product_cost_total: 0.0,
        real_profit_total: nil,
        real_margin_pct: nil,
        real_profit_available: false,
        fee_composition: [],
        reconciliation: []
      }
    end

    # Plataformas cobertas pelo filtro de canal atual do dashboard — sem
    # filtro, todas as plataformas com Channel do tenant.
    def filtered_platforms
      @filtered_platforms ||= begin
        scope = tenant.channels
        scope = scope.where(id: channel_ids) if channel_ids.present?
        scope.distinct.pluck(:platform)
      end
    end

    # Item-level discount composition — which products concentrate the
    # discounts given in the period. Uses order_items.discount (populated by
    # the channel normalizers), so it only sees discounts the channel
    # attributes to a specific item; order-level discounts with no item
    # split stay out of this cut (they're covered by the type breakdown).
    # Sem margem por produto de propósito: cost_price está zerado em 100%
    # de products/orders em produção (ProductCostSyncJob não persiste), então
    # qualquer margem aqui seria enganosa até isso ser corrigido.
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
          Arel.sql("COALESCE(SUM(order_items.quantity * order_items.unit_price), 0)"),
          Arel.sql("COUNT(DISTINCT order_items.order_id)")
        )

      rows.map do |sku, name, discount_total, net_total, orders_count|
        discount_f = discount_total.to_f
        # order_items.unit_price é o preço LÍQUIDO (pós-desconto) neste
        # schema — o preço de tabela é unit_price + desconto, e é sobre ele
        # que o % é calculado (senão passa de 100%). nf_unit_price não serve
        # de base: está zerado em produção.
        list_price_f = net_total.to_f + discount_f

        {
          sku: sku,
          name: name.presence || sku,
          discount_total: discount_f.round(2),
          discount_pct: list_price_f > 0 ? (discount_f / list_price_f * 100).round(2) : 0.0,
          orders_count: orders_count.to_i
        }
      end
    end

    # Card "Desconto por ticket": incidência de desconto sobre os pedidos
    # válidos do período. avg_discount_per_order é a média ENTRE os pedidos
    # com desconto (não dilui pelos sem desconto).
    def build_discount_ticket_summary(scope)
      total = scope.count
      discounted_scope = scope.where("COALESCE(discount, 0) > 0")
      discounted = discounted_scope.count
      avg = discounted.positive? ? discounted_scope.average(:discount).to_f : 0.0

      {
        discounted_orders_count: discounted,
        total_orders_count: total,
        discount_rate_pct: total.positive? ? (discounted.to_f / total * 100).round(2) : 0.0,
        avg_discount_per_order: avg.round(2)
      }
    end

    # Exposição a desconto por produto: em quantos PEDIDOS que contêm o
    # produto o pedido teve desconto (orders.discount > 0), vs o total de
    # pedidos que contêm o produto. É contagem de pedidos de propósito —
    # NÃO ratear valor de desconto por item aqui: a API do Yampi só expõe
    # desconto por pedido, qualquer valor por item seria estimativa.
    def build_product_discount_exposure(scope, limit: 10)
      discounted_count_sql = "COUNT(DISTINCT order_items.order_id) FILTER (WHERE COALESCE(orders.discount, 0) > 0)"

      rows = OrderItem
        .joins(:order)
        .where(order_id: scope.select(:id), is_gift: false)
        .group(:sku, :name)
        .order(Arel.sql("#{discounted_count_sql} DESC"))
        .limit(limit)
        .pluck(
          :sku,
          :name,
          Arel.sql(discounted_count_sql),
          Arel.sql("COUNT(DISTINCT order_items.order_id)")
        )

      rows.map do |sku, name, discounted, total|
        discounted_i = discounted.to_i
        total_i = total.to_i

        {
          sku: sku,
          name: name.presence || sku,
          discounted_orders_count: discounted_i,
          total_orders_count: total_i,
          exposure_pct: total_i.positive? ? (discounted_i.to_f / total_i * 100).round(2) : 0.0
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
      missing_freight_order_ids = real_freight_source? ? scope.where(real_freight_cost: nil).pluck(:id) : []
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
        latest_idworks_sync_at: [ latest_idworks_cost_log&.finished_at, latest_idworks_order_log&.finished_at ].compact.max,
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
        latest_idworks_at = [ latest_idworks_cost_log&.finished_at, latest_idworks_order_log&.finished_at ].compact.max
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
        .merge(Order.revenue_countable)
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
        .merge(Order.revenue_countable)
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
        .merge(Order.revenue_countable)
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

    # Abandoned-cart panel. Yampi feeds it real checkout carts (polling +
    # webhook); TikTok Shop has no pre-checkout cart API, so its proxy is
    # UNPAID orders materialized as Cart rows by
    # Integrations::Tiktok::UnpaidOrdersSyncService — same Cart#status
    # abandoned/converted semantics, so conversion ("recovered") means the
    # same thing on both channels. Scoped by abandoned_at, honoring the same
    # channel filter as the rest of the summary. Guarded so the summary
    # keeps working before the carts migration has run.
    def build_cart_abandonment(period)
      return empty_cart_abandonment unless carts_available?

      scope = tenant.carts.where(abandoned_at: period_range(period))
      scope = scope.where(channel_id: channel_ids) if channel_ids.present?

      total_count, converted_count, abandoned_count, abandoned_value, converted_value,
        abandoned_avg_ticket, generic_discount, promocode, progressive, combos, shipment_discount = scope.pick(
          Arel.sql("COUNT(*)"),
          Arel.sql("COUNT(*) FILTER (WHERE status = 'converted')"),
          Arel.sql("COUNT(*) FILTER (WHERE status = 'abandoned')"),
          Arel.sql("COALESCE(SUM(total) FILTER (WHERE status = 'abandoned'), 0)"),
          Arel.sql("COALESCE(SUM(total) FILTER (WHERE status = 'converted'), 0)"),
          Arel.sql("COALESCE(AVG(total) FILTER (WHERE status = 'abandoned'), 0)"),
          Arel.sql("COALESCE(SUM(discount), 0)"),
          Arel.sql("COALESCE(SUM(promocode_discount), 0)"),
          Arel.sql("COALESCE(SUM(progressive_discount), 0)"),
          Arel.sql("COALESCE(SUM(combos_discount), 0)"),
          Arel.sql("COALESCE(SUM(shipment_discount), 0)")
        ) || Array.new(11, 0)

      total_count = total_count.to_i
      converted_count = converted_count.to_i

      {
        available: true,
        mode: cart_abandonment_mode,
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
        abandoned_avg_ticket: abandoned_avg_ticket.to_f.round(2),
        # Confirmed against real production payloads (2026-07-16):
        # totalizers.promocode_discount_value never shows up in practice —
        # the observed discount lives in the generic totalizers.discount
        # (e.g. Pix/payment-method discount via metadata.discount_highlight,
        # coupon, etc). "other" is the real-world bucket; "coupon"
        # (promocode_discount) is kept as a legacy line, almost always zero.
        discount_composition: [
          { key: "other", label: "Outros descontos (pagamento/cupom)", amount: generic_discount.to_f.round(2) },
          { key: "progressive", label: "Desconto progressivo", amount: progressive.to_f.round(2) },
          { key: "combo", label: "Combos", amount: combos.to_f.round(2) },
          { key: "shipping", label: "Desconto de frete", amount: shipment_discount.to_f.round(2) },
          { key: "coupon", label: "Cupom (legado)", amount: promocode.to_f.round(2) }
        ],
        daily_series: build_cart_daily_series(scope, period),
        top_abandoned_products: build_top_abandoned_products(scope)
      }
    end

    def build_cart_daily_series(scope, period)
      grouped = scope.group(Arel.sql("DATE(abandoned_at)"), :status).count

      (period[:from]..period[:to]).map do |date|
        {
          date: date.iso8601,
          abandoned_count: grouped[[ date, "abandoned" ]].to_i,
          recovered_count: grouped[[ date, "converted" ]].to_i
        }
      end
    end

    # Frequency of products inside still-abandoned carts, read from the
    # cart's stored raw_payload (items.data, the shape the listing include
    # returns). Ruby-side extraction on purpose: item shape isn't uniform
    # across listing vs webhook payloads, so defensive digging beats a
    # rigid jsonb SQL path.
    def build_top_abandoned_products(scope, limit: 10)
      counts = {}

      scope.abandoned.select(:id, :raw_payload).find_each do |cart|
        raw_items = cart.raw_payload.is_a?(Hash) ? cart.raw_payload["items"] : nil
        # Yampi listing: { "items" => { "data" => [...] } }; webhook e o
        # proxy TikTok (UnpaidOrdersSyncService): { "items" => [...] }.
        items = raw_items.is_a?(Hash) ? raw_items["data"] : raw_items
        next unless items.is_a?(Array)

        seen_in_cart = Set.new
        items.each do |item|
          next unless item.is_a?(Hash)

          sku = (item["item_sku"] ||
            (item["sku"].is_a?(String) ? item["sku"] : nil) ||
            item.dig("sku", "data", "sku")).to_s
          name = (item["name"].presence || item.dig("sku", "data", "title").presence || sku).to_s
          next if sku.blank? && name.blank?

          key = sku.presence || name
          entry = counts[key] ||= { sku: sku.presence, name: name, carts_count: 0, total_qty: 0 }
          entry[:total_qty] += (item["quantity"] || item["qty"] || 1).to_i
          entry[:carts_count] += 1 unless seen_in_cart.include?(key)
          seen_in_cart << key
        end
      end

      counts.values.sort_by { |e| [ -e[:carts_count], -e[:total_qty] ] }.first(limit)
    end

    # Freight margin is read from locally synced freight_margin_dailies —
    # never from an external API on dashboard load. "Custo real" has a
    # channel-specific source: carrier cost via LucroFrete/Melhor Envio for
    # Yampi-compatible shipments, and TikTok Shop's own
    # payment.original_shipping_fee for TikTok platform logistics. Honors the
    # summary's period and channel filters. margin_percent is recomputed as a
    # weighted total (margin / charged), not an average of daily percents.
    def build_freight_margin(period)
      return empty_freight_margin unless freight_margin_available?

      scope = tenant.freight_margin_dailies.where(date: period[:from]..period[:to])
      scope = scope.where(channel_id: channel_ids) if channel_ids.present?

      order_count, charged, cost, margin = scope.pick(
        Arel.sql("COALESCE(SUM(order_count), 0)"),
        Arel.sql("COALESCE(SUM(freight_charged), 0)"),
        Arel.sql("COALESCE(SUM(freight_cost), 0)"),
        Arel.sql("COALESCE(SUM(margin_value), 0)")
      ) || Array.new(4, 0)

      charged_f = charged.to_f
      margin_f = margin.to_f
      rows = scope.order(:date).group(:date).pluck(
        :date,
        Arel.sql("COALESCE(SUM(order_count), 0)"),
        Arel.sql("COALESCE(SUM(freight_charged), 0)"),
        Arel.sql("COALESCE(SUM(freight_cost), 0)"),
        Arel.sql("COALESCE(SUM(margin_value), 0)")
      ).to_h { |date, *values| [ date, values ] }

      daily_series = (period[:from]..period[:to]).map do |date|
        day_orders, day_charged, day_cost, day_margin = rows[date] || [ 0, 0, 0, 0 ]
        {
          date: date.iso8601,
          order_count: day_orders.to_i,
          freight_charged: day_charged.to_f.round(2),
          freight_cost: day_cost.to_f.round(2),
          margin_value: day_margin.to_f.round(2)
        }
      end

      {
        available: true,
        order_count: order_count.to_i,
        freight_charged: charged_f.round(2),
        freight_cost: cost.to_f.round(2),
        margin_value: margin_f.round(2),
        margin_percent: charged_f.positive? ? (margin_f / charged_f * 100).round(2) : nil,
        last_synced_at: scope.maximum(:synced_at),
        daily_series: daily_series
      }
    end

    def freight_margin_available?
      return @freight_margin_available if defined?(@freight_margin_available)

      @freight_margin_available = FreightMarginDaily.table_exists?
    rescue StandardError
      @freight_margin_available = false
    end

    def empty_freight_margin
      {
        available: false,
        order_count: 0,
        freight_charged: 0.0,
        freight_cost: 0.0,
        margin_value: 0.0,
        margin_percent: nil,
        last_synced_at: nil,
        daily_series: []
      }
    end

    def carts_available?
      return @carts_available if defined?(@carts_available)

      @carts_available = Cart.table_exists?
    rescue StandardError
      @carts_available = false
    end

    # Drives the gadget's per-channel subtitle/labels: "tiktok_unpaid" only
    # when the channel filter is TikTok-only; any other selection (empty =
    # all channels, Yampi, mixed) keeps the current Yampi checkout framing.
    def cart_abandonment_mode
      return "yampi_checkout" if channel_ids.blank?

      platforms = tenant.channels.where(id: channel_ids).distinct.pluck(:platform)
      platforms.present? && platforms.all?("tiktok") ? "tiktok_unpaid" : "yampi_checkout"
    end

    def empty_cart_abandonment
      {
        available: false,
        mode: cart_abandonment_mode,
        total_count: 0,
        recovered: { count: 0, value: 0.0 },
        still_abandoned: { count: 0, value: 0.0 },
        conversion_rate_pct: 0.0,
        abandoned_avg_ticket: 0.0,
        discount_composition: [],
        daily_series: [],
        top_abandoned_products: []
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
        platform_incentive_total: 0.0,
        platform_incentive_orders_count: 0,
        usage_percentage: 0.0,
        breakdown: [],
        top_coupons: [],
        discount_breakdown_yampi: { available: false, orders_count: 0, discount_total: 0.0, top_coupons: [] },
        discount_breakdown_tiktok: empty_tiktok_discount_breakdown,
        by_product: []
      }
    end

    def empty_tiktok_discount_breakdown
      {
        available: false,
        orders_count: 0,
        financial_synced_orders_count: 0,
        financial_coverage_percentage: 0.0,
        reference_price_total: 0.0,
        effective_revenue_total: 0.0,
        buyer_paid_product_total: 0.0,
        seller_discount_total: 0.0,
        seller_discount_orders_count: 0,
        platform_subsidy_total: 0.0,
        platform_subsidy_orders_count: 0,
        seller_shipping_subsidy_total: 0.0,
        platform_shipping_subsidy_total: 0.0,
        discount_total: 0.0,
        vendor_funded_total: 0.0,
        platform_incentive_total: 0.0
      }
    end

    def product_cost_for(scope)
      item_scope_for(scope)
        .where("unit_cost IS NOT NULL AND unit_cost > 0")
        .sum(Arel.sql("quantity * unit_cost"))
        .to_f
    end

    def freight_for(scope)
      if real_freight_source?
        scope.where.not(real_freight_cost: nil).sum(:real_freight_cost).to_f
      else
        scope.sum(:freight).to_f
      end
    end

    # Fontes que persistem o custo real em real_freight_cost (espelha
    # Order::REAL_FREIGHT_COST_SOURCES).
    def real_freight_source?
      Order::REAL_FREIGHT_COST_SOURCES.include?(data_source_for("freight"))
    end

    def taxes_for(scope)
      tax_source_configured? ? scope.where.not(tax_amount: nil).sum(:tax_amount).to_f : 0.0
    end

    def tax_source_configured?
      data_source_for("tax").present?
    end

    # Fonte única de taxa de gateway: FinancialSettlementItem.fee_amount
    # (já inclui anticipation_fee, ver PagarmePayableSyncService#total_fee).
    # FinancialReceivable também guarda fee_amount do MESMO payable, mas
    # separado de anticipation_fee_amount — somar os dois registros pra
    # essa métrica duplicaria o valor. transaction_date (não payout_date)
    # pra ficar consistente com build_reconciliation, que já filtra
    # FinancialSettlementItem por essa mesma coluna.
    #
    # apply_channel_filter: false ignora o filtro de canal do dashboard —
    # usado só pelo cálculo da média por pedido Yampi (gateway_fee_avg_per_order),
    # que precisa do total real de taxa Pagar.me independente do que está
    # filtrado na tela (ver comentário em build_financial).
    def gateway_fees_for(period, apply_channel_filter: true)
      return 0.0 unless payment_reconciliation_source_configured?

      scope = tenant.financial_settlement_items
        .joins(:financial_settlement)
        .where(financial_settlements: { financial_source_id: pagarme_financial_source_ids })
        .where(transaction_date: period[:from].beginning_of_day..period[:to].end_of_day)
      scope = scope.where(financial_settlements: { channel_id: channel_ids }) if apply_channel_filter && channel_ids.present?

      scope.sum(:fee_amount).to_f
    end

    def pagarme_financial_source_ids
      @pagarme_financial_source_ids ||= tenant.financial_sources.where(provider: "pagarme").pluck(:id)
    end

    def payment_reconciliation_source_configured?
      data_source_for("payment_reconciliation") == "pagarme"
    end

    # Sempre pedidos do canal Yampi, independente do filtro de canal ativo
    # no dashboard — TikTok não passa pela Pagar.me, então misturar os
    # dois na média não faria sentido nem quando "todos os canais" estiver
    # selecionado.
    def yampi_orders_count(period)
      financial_orders(tenant.orders.where(ordered_at: period[:from].beginning_of_day..period[:to].end_of_day))
        .joins(:channel)
        .where(channels: { platform: "yampi" })
        .count
    end

    def gateway_fee_avg_per_order(period)
      return nil unless payment_reconciliation_source_configured?

      orders_count = yampi_orders_count(period)
      return nil unless orders_count.positive?

      (gateway_fees_for(period, apply_channel_filter: false) / orders_count).round(2)
    end

    def freight_tooltip
      case data_source_for("freight")
      when "idworks" then "Soma de real_freight_cost importado do IDWorks."
      when "lucrofrete" then "Soma de real_freight_cost dos pedidos casados via LucroFrete."
      else "Soma de freight dos pedidos."
      end
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
