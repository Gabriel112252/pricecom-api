module Customers
  class Cohorts
    def self.call(tenant:)
      new(tenant: tenant).call
    end

    def initialize(tenant:)
      @tenant = tenant
      @connection = ActiveRecord::Base.connection
    end

    def call
      rows = connection.exec_query(<<~SQL).to_a
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
            AND o.ordered_at IS NOT NULL
        ),
        ordered AS (
          SELECT
            bo.*,
            ROW_NUMBER() OVER (
              PARTITION BY bo.customer_key
              ORDER BY bo.ordered_at ASC, bo.id ASC
            ) AS order_index
          FROM base_orders bo
        ),
        firsts AS (
          SELECT
            customer_key,
            ordered_at AS first_purchase_at,
            net_product_value AS first_order_value
          FROM ordered
          WHERE order_index = 1
        ),
        customer_lifetime AS (
          SELECT
            f.customer_key,
            f.first_purchase_at,
            f.first_order_value,
            MIN(o.ordered_at) FILTER (WHERE o.order_index = 2) AS second_purchase_at,
            SUM(o.net_product_value) FILTER (WHERE o.ordered_at <= f.first_purchase_at + INTERVAL '30 days') AS revenue_30,
            SUM(o.net_product_value) FILTER (WHERE o.ordered_at <= f.first_purchase_at + INTERVAL '60 days') AS revenue_60,
            SUM(o.net_product_value) FILTER (WHERE o.ordered_at <= f.first_purchase_at + INTERVAL '90 days') AS revenue_90
          FROM firsts f
          JOIN ordered o ON o.customer_key = f.customer_key
          GROUP BY f.customer_key, f.first_purchase_at, f.first_order_value
        )
        SELECT
          TO_CHAR(DATE_TRUNC('month', first_purchase_at), 'YYYY-MM') AS cohort,
          COUNT(*)::integer AS customers,
          ROUND(AVG(first_order_value), 2) AS first_order_aov,

          COUNT(*) FILTER (WHERE first_purchase_at <= CURRENT_DATE - INTERVAL '30 days')::integer AS mature_30,
          COUNT(*) FILTER (
            WHERE first_purchase_at <= CURRENT_DATE - INTERVAL '30 days'
              AND second_purchase_at <= first_purchase_at + INTERVAL '30 days'
          )::integer AS repeat_30,
          ROUND(
            100.0 * COUNT(*) FILTER (
              WHERE first_purchase_at <= CURRENT_DATE - INTERVAL '30 days'
                AND second_purchase_at <= first_purchase_at + INTERVAL '30 days'
            ) / NULLIF(COUNT(*) FILTER (WHERE first_purchase_at <= CURRENT_DATE - INTERVAL '30 days'), 0),
            2
          ) AS f2_30_pct,
          ROUND(
            SUM(revenue_30) FILTER (WHERE first_purchase_at <= CURRENT_DATE - INTERVAL '30 days')
            / NULLIF(COUNT(*) FILTER (WHERE first_purchase_at <= CURRENT_DATE - INTERVAL '30 days'), 0),
            2
          ) AS ltv_30,

          COUNT(*) FILTER (WHERE first_purchase_at <= CURRENT_DATE - INTERVAL '60 days')::integer AS mature_60,
          COUNT(*) FILTER (
            WHERE first_purchase_at <= CURRENT_DATE - INTERVAL '60 days'
              AND second_purchase_at <= first_purchase_at + INTERVAL '60 days'
          )::integer AS repeat_60,
          ROUND(
            100.0 * COUNT(*) FILTER (
              WHERE first_purchase_at <= CURRENT_DATE - INTERVAL '60 days'
                AND second_purchase_at <= first_purchase_at + INTERVAL '60 days'
            ) / NULLIF(COUNT(*) FILTER (WHERE first_purchase_at <= CURRENT_DATE - INTERVAL '60 days'), 0),
            2
          ) AS f2_60_pct,
          ROUND(
            SUM(revenue_60) FILTER (WHERE first_purchase_at <= CURRENT_DATE - INTERVAL '60 days')
            / NULLIF(COUNT(*) FILTER (WHERE first_purchase_at <= CURRENT_DATE - INTERVAL '60 days'), 0),
            2
          ) AS ltv_60,

          COUNT(*) FILTER (WHERE first_purchase_at <= CURRENT_DATE - INTERVAL '90 days')::integer AS mature_90,
          COUNT(*) FILTER (
            WHERE first_purchase_at <= CURRENT_DATE - INTERVAL '90 days'
              AND second_purchase_at <= first_purchase_at + INTERVAL '90 days'
          )::integer AS repeat_90,
          ROUND(
            100.0 * COUNT(*) FILTER (
              WHERE first_purchase_at <= CURRENT_DATE - INTERVAL '90 days'
                AND second_purchase_at <= first_purchase_at + INTERVAL '90 days'
            ) / NULLIF(COUNT(*) FILTER (WHERE first_purchase_at <= CURRENT_DATE - INTERVAL '90 days'), 0),
            2
          ) AS f2_90_pct,
          ROUND(
            SUM(revenue_90) FILTER (WHERE first_purchase_at <= CURRENT_DATE - INTERVAL '90 days')
            / NULLIF(COUNT(*) FILTER (WHERE first_purchase_at <= CURRENT_DATE - INTERVAL '90 days'), 0),
            2
          ) AS ltv_90
        FROM customer_lifetime
        GROUP BY DATE_TRUNC('month', first_purchase_at)
        ORDER BY DATE_TRUNC('month', first_purchase_at) DESC
      SQL

      {
        explanation: "Coorte é o grupo de clientes que fez a primeira compra no mesmo mês. F2 mostra quantos fizeram a segunda compra dentro da janela; LTV mostra a receita média acumulada por cliente.",
        maturity_note: "Uma janela só aparece quando o cliente já teve tempo real para completá-la; clientes ainda imaturos não entram no denominador.",
        rows: rows.map { |row| serialize(row) }
      }
    end

    private

    attr_reader :tenant, :connection

    def quoted_list(values)
      values.map { |value| connection.quote(value) }.join(", ")
    end

    def serialize(row)
      {
        cohort: row["cohort"],
        customers: row["customers"].to_i,
        first_order_aov: decimal(row["first_order_aov"]),
        f2_30_pct: decimal(row["f2_30_pct"]),
        ltv_30: decimal(row["ltv_30"]),
        mature_30: row["mature_30"].to_i,
        f2_60_pct: decimal(row["f2_60_pct"]),
        ltv_60: decimal(row["ltv_60"]),
        mature_60: row["mature_60"].to_i,
        f2_90_pct: decimal(row["f2_90_pct"]),
        ltv_90: decimal(row["ltv_90"]),
        mature_90: row["mature_90"].to_i
      }
    end

    def decimal(value)
      value.nil? ? nil : value.to_f.round(2)
    end
  end
end
