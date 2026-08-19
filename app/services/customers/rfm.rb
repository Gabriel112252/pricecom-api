module Customers
  class Rfm
    LIMIT = 200

    def self.call(tenant:)
      new(tenant: tenant).call
    end

    def initialize(tenant:)
      @tenant = tenant
      @connection = ActiveRecord::Base.connection
    end

    def call
      summary = connection.exec_query(summary_sql).first || {}
      cuts = monetary_cuts(summary)
      rows = connection.exec_query(rows_sql(cuts)).to_a

      {
        mode: "partial",
        title: "RFM — Recência, Frequência e Valor",
        explanation: "Frequência e valor já são pontuados com os dados atuais. A nota de Recência e os segmentos completos ficam desligados até termos ciclo de reposição confiável por produto, para não classificar clientes como 'em risco' cedo demais.",
        scores: {
          recency: { available: false, label: "Recência", reason: "Aguardando ciclo de reposição por produto." },
          frequency: { available: true, label: "Frequência", rule: "1 compra=F1; 2=F2; 3=F3; 4–5=F4; 6+=F5" },
          monetary: {
            available: true,
            label: "Valor",
            rule: "Quintis do valor acumulado da base; enquanto a margem completa não estiver disponível, usa receita líquida como aproximação.",
            cuts: cuts
          }
        },
        maturity: {
          total_customers: summary["total_customers"].to_i,
          customers_f2_plus: summary["customers_f2_plus"].to_i,
          f2_plus_pct: summary["f2_plus_pct"]&.to_f&.round(2),
          full_rfm_trigger_pct: 10.0
        },
        rows: rows.map { |row| serialize_row(row) },
        limit: LIMIT
      }
    end

    private

    attr_reader :tenant, :connection

    def base_orders_sql
      <<~SQL
        SELECT
          o.id,
          LOWER(TRIM(o.customer_email)) AS customer_key,
          o.customer_email,
          o.customer_name,
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
      SQL
    end

    def summary_sql
      <<~SQL
        WITH base_orders AS (
          #{base_orders_sql}
        ),
        agg AS (
          SELECT customer_key, COUNT(*)::integer AS orders_count, SUM(net_product_value)::numeric AS total_spent
          FROM base_orders
          GROUP BY customer_key
        )
        SELECT
          COUNT(*)::integer AS total_customers,
          COUNT(*) FILTER (WHERE orders_count >= 2)::integer AS customers_f2_plus,
          ROUND(100.0 * COUNT(*) FILTER (WHERE orders_count >= 2) / NULLIF(COUNT(*), 0), 2) AS f2_plus_pct,
          ROUND(PERCENTILE_CONT(0.20) WITHIN GROUP (ORDER BY total_spent)::numeric, 2) AS m_q20,
          ROUND(PERCENTILE_CONT(0.40) WITHIN GROUP (ORDER BY total_spent)::numeric, 2) AS m_q40,
          ROUND(PERCENTILE_CONT(0.60) WITHIN GROUP (ORDER BY total_spent)::numeric, 2) AS m_q60,
          ROUND(PERCENTILE_CONT(0.80) WITHIN GROUP (ORDER BY total_spent)::numeric, 2) AS m_q80
        FROM agg
      SQL
    end

    def rows_sql(cuts)
      q20, q40, q60, q80 = cuts.map { |value| value || 0.0 }

      <<~SQL
        WITH base_orders AS (
          #{base_orders_sql}
        ),
        ranked_orders AS (
          SELECT
            bo.*,
            ROW_NUMBER() OVER (
              PARTITION BY bo.customer_key
              ORDER BY bo.ordered_at DESC NULLS LAST, bo.id DESC
            ) AS last_rank
          FROM base_orders bo
        ),
        customer_agg AS (
          SELECT
            customer_key,
            COUNT(*)::integer AS orders_count,
            SUM(net_product_value)::numeric AS total_spent,
            MAX(ordered_at) AS last_purchase_at
          FROM base_orders
          GROUP BY customer_key
        ),
        scored AS (
          SELECT
            ca.*,
            CASE
              WHEN ca.orders_count = 1 THEN 1
              WHEN ca.orders_count = 2 THEN 2
              WHEN ca.orders_count = 3 THEN 3
              WHEN ca.orders_count BETWEEN 4 AND 5 THEN 4
              ELSE 5
            END AS score_f,
            CASE
              WHEN ca.total_spent <= #{q20.to_f} THEN 1
              WHEN ca.total_spent <= #{q40.to_f} THEN 2
              WHEN ca.total_spent <= #{q60.to_f} THEN 3
              WHEN ca.total_spent <= #{q80.to_f} THEN 4
              ELSE 5
            END AS score_m
          FROM customer_agg ca
        ),
        final AS (
          SELECT
            s.*,
            GREATEST((CURRENT_DATE - s.last_purchase_at::date), 0)::integer AS recency_days,
            CEIL((s.score_f + s.score_m) / 2.0)::integer AS score_fm,
            l.customer_name,
            l.customer_email
          FROM scored s
          JOIN ranked_orders l ON l.customer_key = s.customer_key AND l.last_rank = 1
        )
        SELECT *
        FROM final
        ORDER BY score_fm DESC, total_spent DESC, recency_days ASC, customer_key ASC
        LIMIT #{LIMIT}
      SQL
    end

    def monetary_cuts(summary)
      [ "m_q20", "m_q40", "m_q60", "m_q80" ].map do |key|
        summary[key]&.to_f&.round(2)
      end
    end

    def quoted_list(values)
      values.map { |value| connection.quote(value) }.join(", ")
    end

    def serialize_row(row)
      {
        customer_key: row["customer_key"],
        name: row["customer_name"],
        email: row["customer_email"],
        recency_days: row["recency_days"].to_i,
        orders_count: row["orders_count"].to_i,
        total_spent: row["total_spent"].to_f.round(2),
        score_r: nil,
        score_f: row["score_f"].to_i,
        score_m: row["score_m"].to_i,
        score_fm: row["score_fm"].to_i,
        segment: nil
      }
    end
  end
end
