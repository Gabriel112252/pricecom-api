module Customers
  class BaseQuery
    DEFAULT_PER_PAGE = 50
    MAX_PER_PAGE = 100

    SORTS = {
      "total_spent" => "total_spent",
      "orders_count" => "orders_count",
      "average_ticket" => "average_ticket",
      "last_purchase_at" => "last_purchase_at",
      "first_purchase_at" => "first_purchase_at",
      "recency_days" => "recency_days"
    }.freeze

    def self.call(tenant:, params:)
      new(tenant: tenant, params: params).call
    end

    def initialize(tenant:, params:)
      @tenant = tenant
      @params = params
      @connection = ActiveRecord::Base.connection
    end

    def call
      page = [ params.fetch(:page, 1).to_i, 1 ].max
      per_page = [ [ params.fetch(:per_page, DEFAULT_PER_PAGE).to_i, 1 ].max, MAX_PER_PAGE ].min
      offset = (page - 1) * per_page

      rows = connection.exec_query(<<~SQL).to_a
        #{customer_ctes}
        SELECT
          cr.*,
          COUNT(*) OVER() AS filtered_count
        FROM customer_rows cr
        #{where_clause}
        ORDER BY #{sort_column} #{sort_direction}, customer_key ASC
        LIMIT #{per_page}
        OFFSET #{offset}
      SQL

      total = rows.first&.fetch("filtered_count", 0).to_i

      {
        rows: rows.map { |row| serialize_row(row) },
        meta: {
          page: page,
          per_page: per_page,
          total: total,
          total_pages: total.zero? ? 0 : (total.to_f / per_page).ceil
        },
        identity: {
          key: "customer_email",
          normalized: true,
          note: "Clientes são consolidados por e-mail normalizado. Canais sem e-mail confiável ainda não entram na união entre canais."
        }
      }
    end

    private

    attr_reader :tenant, :params, :connection

    def customer_ctes
      <<~SQL
        WITH base_orders AS (
          SELECT
            o.id,
            LOWER(TRIM(o.customer_email)) AS customer_key,
            o.customer_email,
            o.customer_name,
            o.state,
            o.channel_id,
            o.ordered_at,
            GREATEST(
              COALESCE(o.gross_value, 0)
              - COALESCE(o.discount, 0)
              - COALESCE(o.freight, 0)
              - COALESCE(o.refund_amount, 0),
              0
            )::numeric AS net_product_value,
            (COALESCE(o.margin, 0) - COALESCE(o.refund_amount, 0))::numeric AS net_margin
          FROM orders o
          WHERE o.tenant_id = #{tenant.id.to_i}
            AND o.order_type = 'sale'
            AND LOWER(COALESCE(o.status, '')) NOT IN (#{quoted_list(Order::CANCELED_STATUS_ALIASES)})
            AND LOWER(COALESCE(o.status, '')) NOT IN (#{quoted_list(Order::NON_REVENUE_STATUSES)})
            AND o.customer_email IS NOT NULL
            AND TRIM(o.customer_email) <> ''
        ),
        ranked_orders AS (
          SELECT
            bo.*,
            ROW_NUMBER() OVER (
              PARTITION BY bo.customer_key
              ORDER BY bo.ordered_at ASC NULLS LAST, bo.id ASC
            ) AS first_rank,
            ROW_NUMBER() OVER (
              PARTITION BY bo.customer_key
              ORDER BY bo.ordered_at DESC NULLS LAST, bo.id DESC
            ) AS last_rank
          FROM base_orders bo
        ),
        aggregates AS (
          SELECT
            customer_key,
            COUNT(*)::integer AS orders_count,
            SUM(net_product_value)::numeric AS total_spent,
            SUM(net_margin)::numeric AS total_margin,
            AVG(net_product_value)::numeric AS average_ticket,
            MIN(ordered_at) AS first_purchase_at,
            MAX(ordered_at) AS last_purchase_at
          FROM base_orders
          GROUP BY customer_key
        ),
        sku_aggregates AS (
          SELECT
            bo.customer_key,
            ARRAY_AGG(DISTINCT oi.sku ORDER BY oi.sku)
              FILTER (WHERE oi.sku IS NOT NULL AND oi.sku <> '' AND COALESCE(oi.is_gift, false) = false) AS purchased_skus
          FROM base_orders bo
          JOIN order_items oi ON oi.order_id = bo.id
          GROUP BY bo.customer_key
        ),
        customer_rows AS (
          SELECT
            a.customer_key,
            COALESCE(NULLIF(l.customer_name, ''), NULLIF(f.customer_name, ''), l.customer_email, f.customer_email) AS customer_name,
            COALESCE(l.customer_email, f.customer_email) AS customer_email,
            COALESCE(NULLIF(l.state, ''), NULLIF(f.state, '')) AS state,
            a.orders_count,
            ROUND(a.total_spent, 2) AS total_spent,
            ROUND(a.total_margin, 2) AS total_margin,
            ROUND(a.average_ticket, 2) AS average_ticket,
            a.first_purchase_at,
            a.last_purchase_at,
            GREATEST((CURRENT_DATE - a.last_purchase_at::date), 0)::integer AS recency_days,
            f.channel_id AS first_channel_id,
            c.name AS first_channel_name,
            c.platform AS first_channel_platform,
            (
              SELECT oi.sku
              FROM order_items oi
              WHERE oi.order_id = f.id
                AND COALESCE(oi.is_gift, false) = false
                AND oi.sku IS NOT NULL
                AND oi.sku <> ''
              ORDER BY oi.id ASC
              LIMIT 1
            ) AS first_sku,
            COALESCE(sa.purchased_skus, ARRAY[]::varchar[]) AS purchased_skus
          FROM aggregates a
          JOIN ranked_orders f ON f.customer_key = a.customer_key AND f.first_rank = 1
          JOIN ranked_orders l ON l.customer_key = a.customer_key AND l.last_rank = 1
          LEFT JOIN channels c ON c.id = f.channel_id
          LEFT JOIN sku_aggregates sa ON sa.customer_key = a.customer_key
        )
      SQL
    end

    def where_clause
      clauses = []

      if params[:q].present?
        pattern = "%#{params[:q].to_s.strip}%"
        quoted = connection.quote(pattern)
        clauses << "(cr.customer_email ILIKE #{quoted} OR cr.customer_name ILIKE #{quoted})"
      end

      clauses << "cr.total_spent >= #{number(params[:min_total_spent])}" if params[:min_total_spent].present?
      clauses << "cr.total_spent <= #{number(params[:max_total_spent])}" if params[:max_total_spent].present?
      clauses << "cr.average_ticket >= #{number(params[:min_average_ticket])}" if params[:min_average_ticket].present?
      clauses << "cr.average_ticket <= #{number(params[:max_average_ticket])}" if params[:max_average_ticket].present?
      clauses << "cr.orders_count >= #{integer(params[:min_orders])}" if params[:min_orders].present?
      clauses << "cr.orders_count <= #{integer(params[:max_orders])}" if params[:max_orders].present?
      clauses << "cr.recency_days >= #{integer(params[:min_recency_days])}" if params[:min_recency_days].present?
      clauses << "cr.recency_days <= #{integer(params[:max_recency_days])}" if params[:max_recency_days].present?
      clauses << "cr.first_purchase_at::date >= #{connection.quote(params[:first_purchase_from].to_s)}" if params[:first_purchase_from].present?
      clauses << "cr.first_purchase_at::date <= #{connection.quote(params[:first_purchase_to].to_s)}" if params[:first_purchase_to].present?
      clauses << "cr.state = #{connection.quote(params[:state].to_s.upcase)}" if params[:state].present?
      clauses << "cr.first_channel_id = #{integer(params[:first_channel_id])}" if params[:first_channel_id].present?

      case params[:repeat].to_s
      when "yes" then clauses << "cr.orders_count >= 2"
      when "no" then clauses << "cr.orders_count = 1"
      end

      if params[:purchased_sku].present?
        clauses << "#{connection.quote(params[:purchased_sku].to_s)} = ANY(cr.purchased_skus)"
      end

      if params[:never_purchased_sku].present?
        clauses << "NOT (#{connection.quote(params[:never_purchased_sku].to_s)} = ANY(cr.purchased_skus))"
      end

      clauses.empty? ? "" : "WHERE #{clauses.join(' AND ')}"
    end

    def sort_column
      SORTS.fetch(params[:sort].to_s, SORTS["total_spent"])
    end

    def sort_direction
      params[:direction].to_s.downcase == "asc" ? "ASC" : "DESC"
    end

    def serialize_row(row)
      {
        customer_key: row["customer_key"],
        name: row["customer_name"],
        email: row["customer_email"],
        state: row["state"],
        orders_count: row["orders_count"].to_i,
        total_spent: row["total_spent"].to_f.round(2),
        total_margin: row["total_margin"].to_f.round(2),
        average_ticket: row["average_ticket"].to_f.round(2),
        first_purchase_at: row["first_purchase_at"],
        last_purchase_at: row["last_purchase_at"],
        recency_days: row["recency_days"].to_i,
        first_channel: {
          id: row["first_channel_id"]&.to_i,
          name: row["first_channel_name"],
          platform: row["first_channel_platform"]
        },
        first_sku: row["first_sku"],
        purchased_skus: Array(row["purchased_skus"])
      }
    end

    def quoted_list(values)
      values.map { |value| connection.quote(value) }.join(", ")
    end

    def number(value)
      value.to_d.to_f
    end

    def integer(value)
      value.to_i
    end
  end
end
