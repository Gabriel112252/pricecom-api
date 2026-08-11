module Dashboard
  # Shared per-item revenue SQL, extracted from BuildSummary so
  # SearchProducts (and any future product-level query) can reuse the exact
  # same TikTok-aware formula instead of re-deriving it — this formula has
  # already been the source of two silent revenue bugs (platform_discount
  # double-counted, then pre-fix order_items mixed with post-fix ones), so a
  # second independent copy is a real drift risk, not just duplication.
  module ProductRevenueSql
    # TiktokOrderNormalizer#extract_items started writing correct
    # order_items.seller_discount/platform_discount on this date — see
    # BuildSummary::TIKTOK_ITEM_DISCOUNT_SPLIT_FIX_DEPLOYED_AT history for
    # the full story (20260726000000_add_seller_and_platform_discount_to_order_items.rb,
    # Integrations::Tiktok::DiscountBackfillService).
    TIKTOK_ITEM_DISCOUNT_SPLIT_FIX_DEPLOYED_AT = Time.zone.parse("2026-07-26").freeze

    private

    # Yampi/Shopify store order_items.unit_price as the GROSS per-unit price
    # and order_items.discount as the real per-item discount, so
    # `quantity * unit_price - discount` is correct for them. TikTok's
    # unit_price is already NET of both seller_discount and
    # platform_discount, so adding platform_discount back lands on TikTok's
    # own "Vendas líquidas dos produtos" (gross - seller_discount only).
    # Requires the query to join order_items -> orders -> channels.
    def item_revenue_amount_sql
      "CASE WHEN channels.platform = 'tiktok' " \
        "THEN order_items.quantity * order_items.unit_price + order_items.platform_discount " \
        "ELSE order_items.quantity * order_items.unit_price - order_items.discount END"
    end

    # Guards item_revenue_amount_sql against mixing pre- and post-fix TikTok
    # order_items in the same SUM (see TIKTOK_ITEM_DISCOUNT_SPLIT_FIX_DEPLOYED_AT).
    # Non-TikTok channels never had this bug, so they're always reliable —
    # this must never filter out Yampi/Shopify/Shopee rows. Requires the
    # same order_items -> orders -> channels join as item_revenue_amount_sql.
    def item_discount_split_reliable_sql
      "channels.platform <> 'tiktok' OR order_items.created_at >= " \
        "#{ActiveRecord::Base.connection.quote(TIKTOK_ITEM_DISCOUNT_SPLIT_FIX_DEPLOYED_AT)}"
    end
  end
end
