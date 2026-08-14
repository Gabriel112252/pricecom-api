module Dashboard
  # Autocomplete-style product search for the "Produtos" dashboard tab.
  # Answers "how many units of SKU X sold in total, across all channels,
  # in this period" — a question the Top 10 revenue/margin rankings can't
  # answer for products outside the top 10. Deliberately mirrors the base
  # scope of BuildSummary#build_top_products_by_revenue (same tenant/period/
  # is_gift/revenue formula) but without .limit(10) or the ranking-only
  # filters (unit_cost > 0, HAVING SUM > 0) — this queries one product at a
  # time, not a leaderboard.
  class SearchProducts
    include Dashboard::ProductRevenueSql

    RESULT_LIMIT = 10

    def self.call(tenant:, params:)
      new(tenant: tenant, params: params).call
    end

    def initialize(tenant:, params:)
      @tenant = tenant
      @params = params
    end

    def call
      { results: matching_products.map { |product| product_result(product) } }
    end

    private

    attr_reader :tenant, :params

    def query
      params[:q].to_s.strip
    end

    def matching_products
      return Product.none if query.blank?

      term = "%#{query}%"
      tenant.products
        .where("sku ILIKE :q OR name ILIKE :q", q: term)
        .order(:sku)
        .limit(RESULT_LIMIT)
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

    def period_range
      @period_range ||= begin
        period = resolve_period
        period[:from].beginning_of_day..period[:to].end_of_day
      end
    end

    def product_scope(product)
      scope = OrderItem
        .joins(:product, order: :channel)
        .merge(Order.sales_and_refunds)
        .where(orders: { tenant_id: tenant.id, ordered_at: period_range })
        .where(is_gift: false, product_id: product.id)
        .where(item_discount_split_reliable_sql)
      scope = scope.where(orders: { channel_id: channel_ids }) if channel_ids.present?
      scope
    end

    # Free samples sent to TikTok creators/affiliates (orders.order_type
    # "sample" — see Order::ORDER_TYPES) are deliberately excluded from
    # product_scope above (they're not a sale), but the volume itself is
    # still relevant to show — separately labeled, never folded into
    # total_qty_sold/total_revenue.
    def sample_scope(product)
      scope = OrderItem
        .joins(:product, order: :channel)
        .where(orders: { tenant_id: tenant.id, ordered_at: period_range, order_type: "sample" })
        .where(is_gift: false, product_id: product.id)
      scope = scope.where(orders: { channel_id: channel_ids }) if channel_ids.present?
      scope
    end

    def product_result(product)
      scope = product_scope(product)

      total_qty, total_revenue = scope.pick(
        Arel.sql("COALESCE(SUM(order_items.quantity), 0)"),
        Arel.sql("COALESCE(SUM(#{item_revenue_amount_sql}), 0)")
      )

      by_channel = scope
        .group("channels.platform")
        .pluck(
          Arel.sql("channels.platform"),
          Arel.sql("COUNT(DISTINCT orders.id)"),
          Arel.sql("SUM(order_items.quantity)"),
          Arel.sql("SUM(#{item_revenue_amount_sql})")
        )
        .map do |platform, orders_count, qty, revenue|
          { platform: platform, orders_count: orders_count, qty_sold: qty.to_f, revenue: revenue.to_f.round(2) }
        end

      sample_qty_sent = sample_scope(product).sum(:quantity)

      {
        sku: product.sku,
        name: product.name,
        total_qty_sold: total_qty.to_f,
        total_revenue: total_revenue.to_f.round(2),
        by_channel: by_channel,
        sample_qty_sent: sample_qty_sent.to_f
      }
    end
  end
end
