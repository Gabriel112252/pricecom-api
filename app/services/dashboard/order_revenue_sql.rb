module Dashboard
  # Shared order-level "receita efetiva" SQL, extracted from BuildSummary so
  # any other service that needs the exact same TikTok-aware formula (e.g.
  # Idworks::DashboardStatsService) doesn't re-derive it independently —
  # same rationale as ProductRevenueSql for the item-level formula.
  module OrderRevenueSql
    private

    # TiktokOrderNormalizer#extract_items started writing correct
    # order_items.seller_discount/platform_discount on this date — see
    # BuildSummary::TIKTOK_ITEM_DISCOUNT_SPLIT_FIX_DEPLOYED_AT history for
    # the full story (20260726000000_add_seller_and_platform_discount_to_order_items.rb,
    # Integrations::Tiktok::DiscountBackfillService).
    #
    # sincronizado usa revenue_amount (confirmado, já líquido de desconto do
    # vendedor + subsídio da plataforma); pedido ainda pendente (backfill em
    # andamento) usa uma ESTIMATIVA — gross_value - seller_discount — em vez
    # de ficar de fora do valor. seller_discount já vem do normalizer de
    # pedido (Get Order Detail, imediato), não do fechamento do statement,
    # então a estimativa está disponível desde a criação do pedido. Nunca é
    # exata: não reflete taxas/comissões/ajustes que só o fechamento revela
    # (ver tiktok_revenue_confirmed_sql para separar os dois casos na UI).
    def tiktok_revenue_sql
      "CASE WHEN orders.financial_synced_at IS NOT NULL THEN orders.revenue_amount " \
        "ELSE GREATEST(COALESCE(orders.gross_value, 0) - COALESCE(orders.seller_discount, 0), 0) END"
    end

    # Predicado companheiro de tiktok_revenue_sql: true quando o valor acima
    # é o revenue_amount confirmado pelo fechamento, false quando é a
    # estimativa. Usado tanto em COUNT(*) FILTER quanto pra decidir, por
    # pedido, se a UI mostra o badge "estimado".
    def tiktok_revenue_confirmed_sql
      "orders.financial_synced_at IS NOT NULL"
    end

    # Regra central de "receita efetiva": canal TikTok usa tiktok_revenue_sql
    # (confirmado quando sincronizado, estimado quando pendente — nunca fica
    # de fora do SUM). Os demais canais preservam a fórmula histórica
    # (gross_value - discount - refund_amount), sem nenhuma mudança de
    # comportamento pra Yampi.
    #
    # Todo widget monetário que soma por pedido deve reutilizar este helper
    # em vez de reimplementar o CASE. Exige que a scope já tenha
    # `.joins(:channel)` (usa channels.platform).
    def effective_revenue_sql
      "CASE " \
        "WHEN channels.platform = 'tiktok' THEN (#{tiktok_revenue_sql}) " \
        "ELSE COALESCE(orders.gross_value, 0) - COALESCE(orders.discount, 0) - COALESCE(orders.refund_amount, 0) " \
      "END"
    end

    # Predicado companheiro de effective_revenue_sql: true quando o valor é
    # CONFIRMADO (não-TikTok, sempre; TikTok só quando sincronizado), false
    # quando é uma estimativa TikTok ainda pendente. Usar só como contador
    # informativo de cobertura (não mais como divisor de ticket médio, já
    # que effective_revenue_sql sempre estima em vez de excluir).
    def financial_revenue_available_sql
      "channels.platform <> 'tiktok' OR (#{tiktok_revenue_confirmed_sql})"
    end
  end
end
