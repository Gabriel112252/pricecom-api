namespace :tiktok do
  desc "Backfill freight_margin_dailies for TikTok from local orders.freight and orders.original_shipping_fee"
  task sync_freight_margins: :environment do
    total_days = 0

    Channel.where(platform: "tiktok").includes(:tenant).find_each do |channel|
      dates = []
      scope = channel.orders
        .sales
        .revenue_countable
        .where.not(original_shipping_fee: nil)
        .where.not(ordered_at: nil)

      scope.select(:id, :ordered_at).find_each do |order|
        dates << order.ordered_at.in_time_zone.to_date
      end

      dates.uniq.sort.each do |date|
        Integrations::Tiktok::FreightMarginDailySyncService.call(scope.first, dates: [ date ])
      end

      total_days += dates.uniq.size
      puts "tenant_id=#{channel.tenant_id} channel_id=#{channel.id} rebuilt_days=#{dates.uniq.size}"
    end

    puts "Done. rebuilt_days=#{total_days}"
  end

  desc "Re-sync TikTok Shop orders after the gross_value fix (TiktokOrderNormalizer used to store the " \
       "POST-discount payment.total_amount as gross_value, double-counting the discount). The raw order " \
       "payload is not persisted anywhere, so the only way to correct already-imported orders is to " \
       "re-fetch them: resets orders_sync_cursor_at on every TikTok ChannelCredential (forcing a fresh " \
       "30-day backfill) and enqueues the polling job. " \
       "UpsertOrder is idempotent by (channel, external_id), so existing orders are " \
       "overwritten in place. Orders created before the backfill window will NOT be re-fetched — the " \
       "task warns about them."
  task resync_orders: :environment do
    backfill_days = Integrations::Tiktok::OrdersPollingService::BACKFILL_DAYS
    window_start = backfill_days.days.ago

    ChannelCredential.where(channel: "tiktok").find_each do |credential|
      stale_count = credential.tenant.orders
        .joins(:channel)
        .where(channels: { platform: "tiktok" })
        .where(ordered_at: ...window_start)
        .count
      if stale_count.positive?
        puts "WARN tenant_id=#{credential.tenant_id}: #{stale_count} pedido(s) TikTok anteriores a " \
             "#{window_start.to_date} ficarão fora do backfill de #{backfill_days} dias e manterão o " \
             "gross_value incorreto"
      end

      credential.update!(orders_sync_cursor_at: nil)
      Integrations::Tiktok::OrdersPollingJob.perform_later(credential.id, trigger: "gross_value_fix_backfill")
      puts "Enqueued backfill for channel_credential_id=#{credential.id} (tenant_id=#{credential.tenant_id})"
    end

    puts "Done."
  end
end
