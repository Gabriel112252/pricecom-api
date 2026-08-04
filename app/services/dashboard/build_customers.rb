module Dashboard
  # Aba "Clientes" — 4 indicadores de recompra: taxa de recompra por
  # cliente (com evolução temporal), % de pedidos que são recompra, tempo
  # até recompra (histograma) e produtos mais recomprados (2 rankings).
  # v1 só suporta o canal Yampi: é o único canal com customer_email
  # persistido (ver YampiOrderNormalizer#extract_customer_email e a
  # migration 20260803120000). TikTok Shop não tem identificador de
  # comprador estável na payload usada hoje — ver Order#customer_tag, que é
  # só uma flag "novo"/"recorrente" autodeclarada pelo canal por PEDIDO, não
  # uma chave de cliente, e por isso não serve pra agrupar.
  class BuildCustomers
    SUPPORTED_CHANNELS = %w[yampi].freeze
    GAP_BUCKET_RANGES = [
      ["0-15", 0...15],
      ["15-30", 15...30],
      ["30-60", 30...60],
      ["60-90", 60...90],
      ["90-180", 90...180],
      ["180+", 180...Float::INFINITY]
    ].freeze
    PRODUCT_RANKING_LIMIT = 12
    MIN_CUSTOMERS_FOR_PRODUCT_PCT_RANKING = 20

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
        repeat_purchase_rate:     build_repeat_purchase_rate(full_scope, period, prev_period, granularity),
        repeat_order_share:       build_repeat_order_share(full_scope, period, granularity),
        repurchase_gap_histogram: build_repurchase_gap_histogram(full_scope),
        repeat_product_rankings:  build_repeat_product_rankings(channel)
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
        repeat_order_share: nil,
        repurchase_gap_histogram: nil,
        repeat_product_rankings: {
          by_volume: [],
          by_customer_pct: [],
          min_customers_threshold: MIN_CUSTOMERS_FOR_PRODUCT_PCT_RANKING
        }
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

    # ---- 1) Taxa de recompra (por cliente) ----

    def build_repeat_purchase_rate(scope, period, prev_period, granularity)
      current  = repeat_purchase_rate_for(scope, period)
      previous = repeat_purchase_rate_for(scope, prev_period)

      {
        value_pct:          current[:rate],
        vs_previous_pct:     pct_change(current[:rate], previous[:rate]),
        total_customers:     current[:total_customers],
        repeat_customers:    current[:repeat_customers],
        orders_without_customer_email_count: current[:orders_without_email],
        timeline: repeat_purchase_timeline_for(scope, period, granularity)
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

    # Mesma fórmula de repeat_purchase_rate_for (clientes com 2+ pedidos /
    # clientes com 1+ pedido), aplicada por bucket em vez de uma vez só
    # pro período inteiro — dá o gráfico de evolução do indicador 1.
    def repeat_purchase_timeline_for(scope, period, granularity)
      rows = scope
        .where(ordered_at: period[:from].beginning_of_day..period[:to].end_of_day)
        .where.not(customer_email: nil)
        .pluck(:customer_email, :ordered_at)

      per_bucket = Hash.new { |h, k| h[k] = Hash.new(0) }
      rows.each do |email, ordered_at|
        bucket_start = granularity == "hour" ? ordered_at.beginning_of_hour : ordered_at.beginning_of_day
        per_bucket[format_bucket(bucket_start, granularity)][email] += 1
      end

      bucket_keys_for(period, granularity).map do |key|
        counts = per_bucket[key] || {}
        total  = counts.size
        repeat = counts.count { |_email, n| n >= 2 }
        {
          bucket: key,
          value_pct: total.positive? ? (repeat.to_f / total * 100).round(2) : nil,
          total_customers: total,
          repeat_customers: repeat
        }
      end
    end

    # ---- 2) % de pedidos que são recompra (por pedido, histórico completo) ----

    # Diferente do indicador 1: aqui a base é o PEDIDO, não o cliente. Um
    # pedido é "recompra" se o cliente já tinha algum pedido válido anterior
    # em TODO o histórico do canal — não só dentro do período selecionado —
    # por isso first_order_at é calculado sobre `scope` sem bound de
    # período (mesma ideia que a extinta build_revenue_by_customer_type já
    # usava pra achar a "primeira compra" do cliente).
    def build_repeat_order_share(scope, period, granularity)
      first_order_at = scope.where.not(customer_email: nil).group(:customer_email).minimum(:ordered_at)

      period_scope = scope.where(ordered_at: period[:from].beginning_of_day..period[:to].end_of_day)
      rows = period_scope.where.not(customer_email: nil).pluck(:customer_email, :ordered_at)
      orders_without_email = period_scope.where(customer_email: nil).count

      per_bucket = Hash.new { |h, k| h[k] = { total: 0, repeat: 0 } }
      total_period = 0
      repeat_period = 0

      rows.each do |email, ordered_at|
        bucket_start = granularity == "hour" ? ordered_at.beginning_of_hour : ordered_at.beginning_of_day
        bucket = per_bucket[format_bucket(bucket_start, granularity)]
        bucket[:total] += 1
        total_period += 1
        if first_order_at[email] && ordered_at > first_order_at[email]
          bucket[:repeat] += 1
          repeat_period += 1
        end
      end

      timeline = bucket_keys_for(period, granularity).map do |key|
        c = per_bucket[key] || { total: 0, repeat: 0 }
        {
          bucket: key,
          value_pct: c[:total].positive? ? (c[:repeat].to_f / c[:total] * 100).round(2) : nil,
          total_orders: c[:total],
          repeat_orders: c[:repeat]
        }
      end

      {
        value_pct: total_period.positive? ? (repeat_period.to_f / total_period * 100).round(2) : nil,
        total_orders: total_period,
        repeat_orders: repeat_period,
        orders_without_customer_email_count: orders_without_email,
        timeline: timeline
      }
    end

    # ---- 3) Tempo até recompra (histograma, histórico completo) ----

    # Pra cada cliente com 2+ pedidos válidos na vida, cada intervalo
    # consecutivo (1º→2º, 2º→3º, ...) vira um ponto de dado independente —
    # cliente com N pedidos contribui N-1 gaps. Ranges meio-abertos
    # [lo, hi) pra um gap de exatamente 15.0/30.0/etc não cair em dois
    # buckets ao mesmo tempo.
    def build_repurchase_gap_histogram(scope)
      orders_by_customer = scope
        .where.not(customer_email: nil)
        .order(:customer_email, :ordered_at)
        .pluck(:customer_email, :ordered_at)
        .group_by(&:first)

      gaps = orders_by_customer.each_value.flat_map do |rows|
        rows.map(&:last).each_cons(2).map { |a, b| (b - a) / 1.day.to_f }
      end

      counts = GAP_BUCKET_RANGES.to_h { |label, _range| [label, 0] }
      gaps.each do |gap|
        label, = GAP_BUCKET_RANGES.find { |_label, range| range.cover?(gap) }
        counts[label] += 1 if label
      end

      {
        buckets: counts.map { |range, count| { range: range, customers_count: count } },
        median_days: median(gaps),
        sample_size: gaps.size
      }
    end

    def median(values)
      return nil if values.empty?

      sorted = values.sort
      mid = sorted.size / 2
      (sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0).round(1)
    end

    # ---- 4) Produtos mais recomprados (2 rankings, histórico completo) ----

    # Mesmo padrão de join usado por Dashboard::BuildSummary#build_top_products_by_*
    # (OrderItem.joins(:product, order: :channel)), mas com o filtro mais
    # estrito de valid_orders (order_type sale/refund + not_canceled +
    # revenue_countable) em vez do filtro mais frouxo que aquele service usa
    # — importante pra ficar consistente com o resto desta aba.
    def valid_order_items(channel)
      OrderItem
        .joins(:product, order: :channel)
        .where(orders: { tenant_id: tenant.id })
        .where(channels: { platform: channel })
        .merge(valid_orders(Order.all))
        .where(is_gift: false)
    end

    # Um row por par (cliente, produto) de todo o histórico, com quantos
    # pedidos distintos aquele cliente fez daquele produto.
    def customer_product_pair_counts(channel)
      rows = valid_order_items(channel)
        .where.not(orders: { customer_email: nil })
        .group("orders.customer_email", "products.id", "products.sku", "products.name")
        .pluck(
          Arel.sql("orders.customer_email"),
          Arel.sql("products.id"),
          Arel.sql("products.sku"),
          Arel.sql("products.name"),
          Arel.sql("COUNT(DISTINCT order_items.order_id)")
        )

      rows.map do |email, product_id, sku, name, order_count|
        { customer_email: email, product_id: product_id, sku: sku, name: name, order_count: order_count.to_i }
      end
    end

    def build_repeat_product_rankings(channel)
      pairs = customer_product_pair_counts(channel)
      by_product = pairs.group_by { |row| row[:product_id] }

      by_volume = by_product.filter_map { |_product_id, rows|
        repeat_count = rows.sum { |row| [row[:order_count] - 1, 0].max }
        next nil if repeat_count.zero?

        { sku: rows.first[:sku], name: rows.first[:name], repeat_purchase_count: repeat_count }
      }.sort_by { |row| -row[:repeat_purchase_count] }.first(PRODUCT_RANKING_LIMIT)

      by_customer_pct = by_product.filter_map { |_product_id, rows|
        total = rows.size
        next nil if total < MIN_CUSTOMERS_FOR_PRODUCT_PCT_RANKING

        repeat = rows.count { |row| row[:order_count] >= 2 }
        {
          sku: rows.first[:sku],
          name: rows.first[:name],
          repeat_customers_pct: (repeat.to_f / total * 100).round(2),
          customers_count: total
        }
      }.sort_by { |row| -row[:repeat_customers_pct] }.first(PRODUCT_RANKING_LIMIT)

      {
        by_volume: by_volume,
        by_customer_pct: by_customer_pct,
        min_customers_threshold: MIN_CUSTOMERS_FOR_PRODUCT_PCT_RANKING
      }
    end
  end
end
