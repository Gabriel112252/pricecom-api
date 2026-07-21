namespace :tiktok do
  desc "Fetch TikTok order details for local paid orders missing payment.original_shipping_fee"
  task backfill_shipping_fee_audit: :environment do
    limit = ENV["LIMIT"].to_i.positive? ? ENV["LIMIT"].to_i : nil
    batch_sleep = ENV["BATCH_SLEEP"].to_f.positive? ? ENV["BATCH_SLEEP"].to_f : 0
    failures = 0

    ChannelCredential.active.where(channel: "tiktok").find_each do |credential|
      result = Integrations::Tiktok::ShippingFeeAuditBackfillService.call(
        credential,
        limit: limit,
        batch_sleep: batch_sleep
      )
      metadata = result.metadata
      puts "tenant_id=#{credential.tenant_id} credential_id=#{credential.id} " \
           "outcome=#{result.outcome} eligible=#{metadata[:eligible_count]} " \
           "filled=#{metadata[:filled_count]} still_missing=#{metadata[:still_missing_count]} " \
           "detail_missing=#{metadata[:detail_missing_count]} api_batches=#{metadata[:api_batches]}"
      failures += 1 if result.error?
    end

    abort "Done with #{failures} failure(s)." if failures.positive?

    puts "Done."
  end

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

  desc "Backfill seller_discount/platform_discount para pedidos TikTok já sincronizados (re-busca cada " \
       "pedido na API do TikTok — ver Integrations::Tiktok::DiscountBackfillService). " \
       "Uso: rake tiktok:backfill_discounts[Hidrabene]"
  task :backfill_discounts, [ :tenant_name ] => :environment do |_t, args|
    tenant_name = args[:tenant_name]
    abort "Uso: rake tiktok:backfill_discounts[NomeDoTenant]" if tenant_name.blank?

    tenant = Tenant.find_by(name: tenant_name)
    abort "Tenant '#{tenant_name}' não encontrado" unless tenant

    credential = tenant.channel_credentials.find_by(channel: "tiktok")
    abort "Tenant '#{tenant_name}' não tem ChannelCredential tiktok" unless credential

    total = tenant.channels.find_by(platform: "tiktok")&.orders&.count.to_i
    puts "Tenant: #{tenant.name} (id=#{tenant.id})"
    puts "Pedidos TikTok encontrados: #{total}"
    puts "Isso re-busca CADA pedido na API do TikTok (Get Order Detail, lotes de " \
         "#{Integrations::Tiktok::DiscountBackfillService::BATCH_SIZE}) e reprocessa o pedido inteiro " \
         "(status, endereço, itens, frete, desconto) — não só as colunas de desconto."
    print "Confirma o início do backfill? (digite 'sim' para continuar): "
    confirmation = $stdin.gets&.strip

    if confirmation != "sim"
      puts "Cancelado."
      next
    end

    job = Integrations::Tiktok::DiscountBackfillJob.perform_later(tenant_id: tenant.id)
    puts "Job enfileirado (job_id: #{job.job_id}). Acompanhe o progresso com:"
    puts "  rake tiktok:backfill_status[#{tenant_name}]"
  end

  desc "Mostra o progresso do backfill de desconto TikTok (IntegrationSyncLog action=" \
       "tiktok_discount_backfill). Uso: rake tiktok:backfill_status[Hidrabene]"
  task :backfill_status, [ :tenant_name ] => :environment do |_t, args|
    tenant_name = args[:tenant_name]
    abort "Uso: rake tiktok:backfill_status[NomeDoTenant]" if tenant_name.blank?

    tenant = Tenant.find_by(name: tenant_name)
    abort "Tenant '#{tenant_name}' não encontrado" unless tenant

    log = IntegrationSyncLog
      .where(tenant: tenant, action: Integrations::Tiktok::DiscountBackfillService::ACTION)
      .order(created_at: :desc)
      .first

    unless log
      puts "Nenhum backfill encontrado para #{tenant_name}."
      next
    end

    meta = log.metadata
    puts "Status: #{log.status}"
    puts "Iniciado em: #{log.started_at}"
    puts "Processados: #{meta['processed_count']} / #{meta['total_orders']}"
    puts "Erros: #{meta['error_count']}"
    puts "Último lote em: #{meta['last_batch_at']}"
    puts "Finalizado em: #{log.finished_at || 'ainda em andamento'}"
    if meta["error_samples"].present?
      puts "Amostra de erros:"
      meta["error_samples"].each { |e| puts "  - #{e}" }
    end
  end

  desc "Enfileira o backfill financeiro histórico dos pedidos TikTok por tenant_slug e max_orders"
  task :financial_backfill, [ :tenant_slug, :max_orders, :batch_size, :batch_sleep, :force ] => :environment do |_t, args|
    usage = "Uso: bin/rails 'tiktok:financial_backfill[tenant_slug,max_orders,batch_size,batch_sleep,force]'"
    tenant_slug = args[:tenant_slug]
    abort usage if tenant_slug.blank?

    raw_max_orders = args[:max_orders]
    abort "#{usage}; max_orders é obrigatório (inteiro positivo ou all)" if raw_max_orders.to_s.strip.blank?

    max_orders = if raw_max_orders.to_s.strip.casecmp?("all")
      nil
    elsif raw_max_orders.to_s.strip.match?(/\A[1-9]\d*\z/)
      raw_max_orders.to_i
    else
      abort "#{usage}; max_orders deve ser um inteiro positivo ou all"
    end

    raw_batch_size = args[:batch_size]
    batch_size = if raw_batch_size.nil?
      50
    elsif raw_batch_size.to_s.strip.match?(/\A[1-9]\d*\z/)
      raw_batch_size.to_i
    else
      abort "#{usage}; batch_size deve ser um inteiro positivo"
    end

    raw_batch_sleep = args[:batch_sleep]
    batch_sleep = if raw_batch_sleep.nil?
      0.5
    elsif raw_batch_sleep.to_s.strip.match?(/\A(?:\d+(?:\.\d+)?|\.\d+)\z/)
      raw_batch_sleep.to_f
    else
      abort "#{usage}; batch_sleep deve ser um número maior ou igual a zero"
    end

    raw_force = args[:force]
    force = if raw_force.nil?
      false
    elsif raw_force.to_s.strip.casecmp?("true")
      true
    elsif raw_force.to_s.strip.casecmp?("false")
      false
    else
      abort "#{usage}; force deve ser true ou false"
    end

    tenant = Tenant.find_by(slug: tenant_slug)
    abort "Tenant '#{tenant_slug}' não encontrado" unless tenant

    credential = tenant.channel_credentials.find_by(channel: "tiktok", status: "active")
    abort "Tenant '#{tenant_slug}' não tem ChannelCredential tiktok ativa" unless credential

    job = Integrations::Tiktok::FinancialBackfillJob.perform_later(
      credential.id,
      batch_size: batch_size,
      batch_sleep: batch_sleep,
      force: force,
      max_orders: max_orders
    )
    puts "job_id=#{job.job_id}"
    puts "tenant_slug=#{tenant_slug}"
    puts "max_orders=#{max_orders || 'all'}"
    puts "batch_size=#{batch_size}"
    puts "batch_sleep=#{batch_sleep}"
    puts "force=#{force}"
    puts "tiktok_financial_backfill_enqueued=true"
  end

  desc "Mostra o último checkpoint do backfill financeiro TikTok por tenant_slug"
  task :financial_backfill_status, [ :tenant_slug ] => :environment do |_t, args|
    tenant_slug = args[:tenant_slug]
    abort "Uso: bin/rails tiktok:financial_backfill_status[tenant_slug]" if tenant_slug.blank?

    tenant = Tenant.find_by(slug: tenant_slug)
    abort "Tenant '#{tenant_slug}' não encontrado" unless tenant

    log = IntegrationSyncLog
      .where(tenant: tenant, action: Integrations::Tiktok::FinancialBackfillService::ACTION)
      .order(created_at: :desc)
      .first

    unless log
      puts "Nenhum backfill financeiro encontrado para #{tenant_slug}."
      next
    end

    metadata = log.metadata || {}
    max_orders = metadata["max_orders"].nil? ? "all" : metadata["max_orders"]

    puts "status=#{log.status}"
    puts "processed_count=#{metadata['processed_count'] || 0}"
    puts "synced_count=#{metadata['synced_count'] || 0}"
    puts "pending_statement_count=#{metadata['pending_statement_count'] || 0}"
    puts "error_count=#{metadata['error_count'] || 0}"
    puts "remaining_orders=#{metadata['remaining_orders'] || 0}"
    puts "last_order_id=#{metadata['last_order_id'] || 'nil'}"
    puts "max_orders=#{max_orders}"
    puts "started_at=#{log.started_at}"
    puts "finished_at=#{log.finished_at || 'nil'}"
  end
end
