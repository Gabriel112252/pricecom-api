module Dashboard
  # Aba "Clientes" — taxa de recompra + receita novos/recorrentes + RFM.
  # v1 só suporta o canal Yampi: é o único canal com customer_email
  # persistido (ver YampiOrderNormalizer#extract_customer_email e a
  # migration 20260803120000). TikTok Shop não tem identificador de
  # comprador estável na payload usada hoje — ver Order#customer_tag, que é
  # só uma flag "novo"/"recorrente" autodeclarada pelo canal por PEDIDO, não
  # uma chave de cliente, e por isso não serve pra agrupar.
  class BuildCustomers
    SUPPORTED_CHANNELS = %w[yampi].freeze

    def self.call(tenant:, params:)
      new(tenant: tenant, params: params).call
    end

    def initialize(tenant:, params:)
      @tenant = tenant
      @params = params
    end

    def call
      channel = params[:channel].to_s.presence || "yampi"
      return unsupported_channel_payload(channel) unless SUPPORTED_CHANNELS.include?(channel)

      period      = resolve_period
      prev_period = previous_period(period)
      granularity = resolve_granularity(period)
      full_scope  = valid_orders(channel_orders(channel))

      {
        channel:      channel,
        supported:    true,
        unsupported_reason: nil,
        period:       { from: period[:from].iso8601, to: period[:to].iso8601 },
        granularity:  granularity,
        repeat_purchase_rate:     build_repeat_purchase_rate(full_scope, period, prev_period),
        revenue_by_customer_type: build_revenue_by_customer_type(full_scope, period, granularity),
        rfm_segments:             build_rfm_segments(full_scope)
      }
    end

    private

    attr_reader :tenant, :params

    def unsupported_channel_payload(channel)
      {
        channel: channel,
        supported: false,
        unsupported_reason: "Sem identificador de cliente confiável para o canal '#{channel}' ainda.",
        period: nil,
        granularity: nil,
        repeat_purchase_rate: nil,
        revenue_by_customer_type: nil,
        rfm_segments: []
      }
    end

    # ---- período — duplicado de propósito a partir de
    # Dashboard::BuildSummary (mesma convenção já usada em
    # DashboardController#resolve_freight_period: reimplementar 4 métodos
    # pequenos e estáveis é mais seguro aqui do que acoplar este service aos
    # internals de um arquivo grande e sensível que não faz parte deste
    # fluxo) ----
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

    def pct_change(current, previous)
      return nil if current.nil? || previous.nil? || previous.to_f.abs < 0.01
      ((current - previous) / previous.to_f * 100).round(2)
    end

    def format_bucket(bucket, granularity)
      granularity == "hour" ? bucket.iso8601 : bucket.to_date.iso8601
    end

    def bucket_keys_for(period, granularity)
      if granularity == "hour"
        day = period[:from].to_time.beginning_of_day
        (0..23).map { |h| format_bucket(day + h.hours, "hour") }
      else
        (period[:from]..period[:to]).map { |d| format_bucket(d, "day") }
      end
    end

    def channel_orders(channel)
      tenant.orders.joins(:channel).where(channels: { platform: channel })
    end

    # Mirrors Dashboard::BuildSummary#financial_orders exactly.
    def valid_orders(scope)
      scope.where(order_type: %w[sale refund]).not_canceled.revenue_countable
    end

    # Mirrors Dashboard::BuildSummary#effective_revenue_sql's non-TikTok
    # branch — este service só atende canais não-TikTok (SUPPORTED_CHANNELS),
    # então o CASE por plataforma daquele helper nunca se aplicaria aqui.
    def effective_revenue_sql
      "(COALESCE(orders.gross_value, 0) - COALESCE(orders.discount, 0) - COALESCE(orders.refund_amount, 0))"
    end

    # ---- 1) Taxa de recompra ----

    def build_repeat_purchase_rate(scope, period, prev_period)
      current  = repeat_purchase_rate_for(scope, period)
      previous = repeat_purchase_rate_for(scope, prev_period)

      {
        value_pct:          current[:rate],
        vs_previous_pct:     pct_change(current[:rate], previous[:rate]),
        total_customers:     current[:total_customers],
        repeat_customers:    current[:repeat_customers],
        orders_without_customer_email_count: current[:orders_without_email]
      }
    end

    def repeat_purchase_rate_for(scope, period)
      period_scope = scope.where(ordered_at: period[:from].beginning_of_day..period[:to].end_of_day)

      counts_by_customer = period_scope.where.not(customer_email: nil).group(:customer_email).count
      orders_without_email = period_scope.where(customer_email: nil).count

      total  = counts_by_customer.size
      repeat = counts_by_customer.count { |_email, orders_count| orders_count >= 2 }
      rate   = total.positive? ? (repeat.to_f / total * 100).round(2) : nil

      { rate: rate, total_customers: total, repeat_customers: repeat, orders_without_email: orders_without_email }
    end

    # ---- 2) Receita: clientes novos vs recorrentes ----

    # "Novo" = pedido em que ordered_at cai no mesmo dia da primeira compra
    # VÁLIDA do cliente em TODO o histórico do canal (não só dentro do
    # período) — ver nota do spec: recompra (item 1) e "primeira compra"
    # (aqui) são cálculos diferentes de propósito.
    def build_revenue_by_customer_type(scope, period, granularity)
      first_order_at = scope.where.not(customer_email: nil).group(:customer_email).minimum(:ordered_at)

      buckets = bucket_keys_for(period, granularity).index_with do
        { new_customer_revenue: 0.0, returning_customer_revenue: 0.0, unknown_customer_revenue: 0.0 }
      end

      rows = scope
        .where(ordered_at: period[:from].beginning_of_day..period[:to].end_of_day)
        .pluck(:customer_email, :ordered_at, Arel.sql(effective_revenue_sql))

      orders_without_email = 0

      rows.each do |email, ordered_at, revenue|
        bucket_start = granularity == "hour" ? ordered_at.beginning_of_hour : ordered_at.beginning_of_day
        key = format_bucket(bucket_start, granularity)
        bucket = (buckets[key] ||= { new_customer_revenue: 0.0, returning_customer_revenue: 0.0, unknown_customer_revenue: 0.0 })

        if email.blank?
          orders_without_email += 1
          bucket[:unknown_customer_revenue] += revenue.to_f
        elsif first_order_at[email]&.to_date == ordered_at.to_date
          bucket[:new_customer_revenue] += revenue.to_f
        else
          bucket[:returning_customer_revenue] += revenue.to_f
        end
      end

      {
        timeline: buckets.map { |date, values|
          {
            date: date,
            new_customer_revenue:       values[:new_customer_revenue].round(2),
            returning_customer_revenue: values[:returning_customer_revenue].round(2),
            unknown_customer_revenue:   values[:unknown_customer_revenue].round(2)
          }
        },
        orders_without_customer_email_count: orders_without_email
      }
    end

    # ---- 3) Segmentação RFM ----
    # Frequência/Monetário sobre o HISTÓRICO COMPLETO do cliente (não só o
    # período selecionado) — decisão do spec pra não penalizar cliente
    # antigo com poucas compras recentes. Recência entra via a ORDEM do
    # último pedido (NTILE), não via contagem de dias — equivalente para
    # fins de quintil e mais simples de expressar em SQL.
    RFM_SEGMENT_RULES = [
      ->(r, f, m) { r >= 4 && f >= 4 && m >= 4 ? "Campeões" : nil },
      ->(r, f, m) { f >= 4 && r >= 3 ? "Fiéis" : nil },
      ->(r, f, m) { r >= 4 && f <= 2 ? "Novos" : nil },
      ->(r, f, m) { r <= 2 && (f >= 4 || m >= 4) ? "Em risco" : nil },
      ->(r, f, m) { r <= 2 && f <= 2 ? "Perdidos" : nil }
    ].freeze

    def classify_rfm_segment(r, f, m)
      RFM_SEGMENT_RULES.each do |rule|
        segment = rule.call(r, f, m)
        return segment if segment
      end
      "Outros"
    end

    def build_rfm_segments(scope)
      customer_agg = scope
        .where.not(customer_email: nil)
        .group(:customer_email)
        .select(
          :customer_email,
          Arel.sql("MAX(orders.ordered_at) AS last_ordered_at"),
          Arel.sql("COUNT(*) AS frequency"),
          Arel.sql("COALESCE(SUM(#{effective_revenue_sql}), 0) AS monetary")
        )

      sql = <<~SQL
        WITH customer_agg AS (#{customer_agg.to_sql})
        SELECT
          customer_email,
          frequency,
          monetary,
          NTILE(5) OVER (ORDER BY last_ordered_at ASC) AS r_score,
          NTILE(5) OVER (ORDER BY frequency ASC)        AS f_score,
          NTILE(5) OVER (ORDER BY monetary ASC)         AS m_score
        FROM customer_agg
      SQL

      rows = ActiveRecord::Base.connection.exec_query(sql)
      return [] if rows.empty?

      segments = Hash.new { |h, k| h[k] = { customers_count: 0, total_revenue: 0.0, total_frequency: 0 } }

      rows.each do |row|
        segment = classify_rfm_segment(row["r_score"].to_i, row["f_score"].to_i, row["m_score"].to_i)
        agg = segments[segment]
        agg[:customers_count]  += 1
        agg[:total_revenue]    += row["monetary"].to_f
        agg[:total_frequency]  += row["frequency"].to_i
      end

      total_customers = rows.count.to_f

      segments.map do |name, agg|
        {
          segment:          name,
          customers_count:  agg[:customers_count],
          pct_of_base:      total_customers.positive? ? (agg[:customers_count] / total_customers * 100).round(2) : 0.0,
          total_revenue:    agg[:total_revenue].round(2),
          avg_order_value:  agg[:total_frequency].positive? ? (agg[:total_revenue] / agg[:total_frequency]).round(2) : 0.0
        }
      end.sort_by { |s| -s[:total_revenue] }
    end
  end
end
