module Dashboard
  # Daily qty/revenue evolution for 1+ specific products, for the "Produtos"
  # tab's comparison chart — extends Dashboard::SearchProducts (period totals
  # only) with a day-by-day breakdown so "how did product X do over time"
  # can be answered, not just "how much in total". Same base scope/revenue
  # formula as SearchProducts (and BuildSummary#build_top_products_by_revenue):
  # OrderItem -> Order.sales_and_refunds, is_gift false, TikTok-aware
  # item_revenue_amount_sql, guarded by item_discount_split_reliable_sql.
  # channel_ids is applied here from day one — this is new code, not a
  # retrofit like the 3 charts that shipped without it.
  class ProductsTimeseries
    include Dashboard::ProductRevenueSql

    def self.call(tenant:, params:)
      new(tenant: tenant, params: params).call
    end

    def initialize(tenant:, params:)
      @tenant = tenant
      @params = params
    end

    def call
      { series: products.map { |product| product_series(product) } }
    end

    private

    attr_reader :tenant, :params

    def skus
      Array(params[:skus]).map { |s| s.to_s.strip }.reject(&:blank?).uniq
    end

    def products
      return Product.none if skus.empty?

      tenant.products.where(sku: skus).order(:sku)
    end

    def channel_ids
      @channel_ids ||= Array(params[:channel_ids]).reject(&:blank?)
    end

    def resolve_period
      to   = params[:to].present?   ? Date.parse(params[:to])   : Date.current
      from = params[:from].present? ? Date.parse(params[:from]) : to - 29.days
      { from: from, to: to }
    rescue ArgumentError
      { from: Date.current - 29.days, to: Date.current }
    end

    def period
      @period ||= resolve_period
    end

    def period_range
      @period_range ||= period[:from].beginning_of_day..period[:to].end_of_day
    end

    # date (Ruby Date) => [qty, revenue], only for days with at least one
    # matching order_item — gaps are filled with zero in #product_series so
    # the frontend line chart never skips a day on the x-axis.
    def daily_rows(product)
      scope = OrderItem
        .joins(:product, order: :channel)
        .merge(Order.sales_and_refunds)
        .where(orders: { tenant_id: tenant.id, ordered_at: period_range })
        .where(is_gift: false, product_id: product.id)
        .where(item_discount_split_reliable_sql)
      scope = scope.where(orders: { channel_id: channel_ids }) if channel_ids.present?

      scope
        .group(Arel.sql("date_trunc('day', orders.ordered_at)"))
        .pluck(
          Arel.sql("date_trunc('day', orders.ordered_at)"),
          Arel.sql("COALESCE(SUM(order_items.quantity), 0)"),
          Arel.sql("COALESCE(SUM(#{item_revenue_amount_sql}), 0)")
        )
        .to_h { |bucket, qty, revenue| [ bucket.to_date, [ qty.to_f, revenue.to_f.round(2) ] ] }
    end

    # Aggregate total for the whole period, not a daily point — free
    # samples (order_type "sample", see Order::ORDER_TYPES) are rare enough
    # per product/day that a full dashed series would mostly be zeros; a
    # single caption number is what the frontend shows next to each
    # product's legend entry.
    def sample_qty_sent(product)
      scope = OrderItem
        .joins(:product, order: :channel)
        .where(orders: { tenant_id: tenant.id, ordered_at: period_range, order_type: "sample" })
        .where(is_gift: false, product_id: product.id)
      scope = scope.where(orders: { channel_id: channel_ids }) if channel_ids.present?
      scope.sum(:quantity)
    end

    def product_series(product)
      rows = daily_rows(product)

      points = (period[:from]..period[:to]).map do |date|
        qty, revenue = rows[date] || [ 0, 0 ]
        { date: date.iso8601, qty_sold: qty, revenue: revenue.round(2) }
      end

      { sku: product.sku, name: product.name, points: points, sample_qty_sent: sample_qty_sent(product).to_f }
    end
  end
end
