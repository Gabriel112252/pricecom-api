module Customers
  class Overview
    def self.call(tenant:)
      new(tenant: tenant).call
    end

    def initialize(tenant:)
      @tenant = tenant
      @connection = ActiveRecord::Base.connection
    end

    def call
      row = connection.exec_query(<<~SQL).first || {}
        WITH base_orders AS (
          SELECT
            o.id,
            LOWER(TRIM(o.customer_email)) AS customer_key,
            o.ordered_at,
            GREATEST(
              COALESCE(o.gross_value, 0)
              - COALESCE(o.discount, 0)
              - COALESCE(o.refund_amount, 0),
              0
            )::numeric AS net_product_value
          FROM orders o
          WHERE o.tenant_id = #{tenant.id.to_i}
            AND o.order_type = 'sale'
            AND LOWER(COALESCE(o.status, '')) NOT IN (#{quoted_list(Order::CANCELED_STATUS_ALIASES)})
            AND LOWER(COALESCE(o.status, '')) NOT IN (#{quoted_list(Order::NON_REVENUE_STATUSES)})
            AND o.customer_email IS NOT NULL
            AND TRIM(o.customer_email) <> ''
        ),
        ordered AS (
          SELECT
            bo.*,
            LAG(bo.ordered_at) OVER (
              PARTITION BY bo.customer_key
              ORDER BY bo.ordered_at ASC NULLS LAST, bo.id ASC
            ) AS previous_order_at
          FROM base_orders bo
        ),
        customer_agg AS (
          SELECT
            customer_key,
            COUNT(*)::integer AS orders_count,
            SUM(net_product_value)::numeric AS total_spent,
            MIN(ordered_at) AS first_purchase_at,
            MAX(ordered_at) AS last_purchase_at
          FROM base_orders
          GROUP BY customer_key
        ),
        ranked_value AS (
          SELECT
            ca.*,
            ROW_NUMBER() OVER (ORDER BY ca.total_spent DESC, ca.customer_key ASC) AS value_rank,
            COUNT(*) OVER() AS base_count
          FROM customer_agg ca
        ),
        gaps AS (
          SELECT EXTRACT(EPOCH FROM (ordered_at - previous_order_at)) / 86400.0 AS gap_days
          FROM ordered
          WHERE previous_order_at IS NOT NULL
            AND ordered_at IS NOT NULL
        )
        SELECT
          COUNT(*)::integer AS total_customers,
          COUNT(*) FILTER (WHERE orders_count >= 2)::integer AS repeat_customers,
          COUNT(*) FILTER (WHERE first_purchase_at >= CURRENT_DATE - INTERVAL '29 days')::integer AS new_customers_30d,
          ROUND(AVG(total_spent), 2) AS average_customer_value,
          ROUND(SUM(total_spent) / NULLIF(SUM(orders_count), 0), 2) AS average_order_ticket,
          ROUND(
            100.0 * COUNT(*) FILTER (WHERE orders_count >= 2) / NULLIF(COUNT(*), 0),
            2
          ) AS repeat_customer_rate,
          ROUND(
            100.0 * SUM(CASE WHEN value_rank <= CEIL(base_count * 0.20) THEN total_spent ELSE 0 END)
            / NULLIF(SUM(total_spent), 0),
            2
          ) AS top20_revenue_share,
          ROUND(PERCENTILE_CONT(0.80) WITHIN GROUP (ORDER BY total_spent)::numeric, 2) AS top20_cutoff,
          (
            SELECT ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY gap_days)::numeric, 1)
            FROM gaps
          ) AS median_repurchase_days
        FROM ranked_value
      SQL

      {
        total_customers: row["total_customers"].to_i,
        repeat_customers: row["repeat_customers"].to_i,
        new_customers_30d: row["new_customers_30d"].to_i,
        average_customer_value: decimal(row["average_customer_value"]),
        average_order_ticket: decimal(row["average_order_ticket"]),
        repeat_customer_rate: decimal(row["repeat_customer_rate"]),
        median_repurchase_days: decimal(row["median_repurchase_days"]),
        top20_revenue_share: decimal(row["top20_revenue_share"]),
        top20_cutoff: decimal(row["top20_cutoff"]),
        coverage: coverage,
        note: "Visão histórica consolidada por e-mail normalizado. Hoje a cobertura de identidade confiável é principalmente Yampi."
      }
    end

    private

    attr_reader :tenant, :connection

    def coverage
      rows = connection.exec_query(<<~SQL).to_a
        SELECT
          c.id AS channel_id,
          c.name AS channel_name,
          c.platform,
          COUNT(*) FILTER (
            WHERE o.customer_email IS NOT NULL AND TRIM(o.customer_email) <> ''
          )::integer AS orders_with_identity,
          COUNT(*)::integer AS total_orders
        FROM orders o
        JOIN channels c ON c.id = o.channel_id
        WHERE o.tenant_id = #{tenant.id.to_i}
          AND o.order_type = 'sale'
          AND LOWER(COALESCE(o.status, '')) NOT IN (#{quoted_list(Order::CANCELED_STATUS_ALIASES)})
          AND LOWER(COALESCE(o.status, '')) NOT IN (#{quoted_list(Order::NON_REVENUE_STATUSES)})
        GROUP BY c.id, c.name, c.platform
        ORDER BY total_orders DESC
      SQL

      rows.map do |row|
        total = row["total_orders"].to_i
        with_identity = row["orders_with_identity"].to_i
        {
          channel_id: row["channel_id"].to_i,
          channel_name: row["channel_name"],
          platform: row["platform"],
          orders_with_identity: with_identity,
          total_orders: total,
          coverage_pct: total.positive? ? (with_identity.to_f / total * 100).round(1) : 0.0
        }
      end
    end

    def quoted_list(values)
      values.map { |value| connection.quote(value) }.join(", ")
    end

    def decimal(value)
      value.nil? ? nil : value.to_f.round(2)
    end
  end
end
