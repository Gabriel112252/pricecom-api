namespace :lucrofrete do
  desc "Backfill historico de Order#real_freight_cost via /api/reports/orders do LucroFrete"
  task backfill_real_freight_cost: :environment do
    parse_date = lambda do |name, value|
      return nil if value.blank?

      Date.parse(value.to_s)
    rescue ArgumentError
      abort "#{name}=#{value.inspect} nao e uma data valida (use YYYY-MM-DD)"
    end

    infer_since = lambda do |tenant|
      yampi = tenant.channels.find_by(platform: "yampi")
      next nil unless yampi

      tenant.orders.where(channel: yampi).minimum(:ordered_at)&.to_date ||
        tenant.orders.where(channel: yampi).minimum(:created_at)&.to_date
    end

    since_date = parse_date.call("SINCE", ENV["SINCE"])
    until_date = parse_date.call("UNTIL", ENV["UNTIL"] || ENV["END_DATE"]) || Date.current
    per_page = (ENV["PER_PAGE"].presence || Integrations::Lucrofrete::OrdersSyncService::DEFAULT_PER_PAGE).to_i
    abort "PER_PAGE precisa ser maior que zero" unless per_page.positive?

    credentials = ChannelCredential.active.where(channel: "lucrofrete")
    credentials = credentials.where(tenant_id: ENV["TENANT_ID"]) if ENV["TENANT_ID"].present?
    if ENV["TENANT_SLUG"].present?
      credentials = credentials.joins(:tenant).where(tenants: { slug: ENV["TENANT_SLUG"] })
    end

    if credentials.none?
      puts "Nenhuma credencial LucroFrete ativa encontrada para os filtros informados."
      next
    end

    credentials.includes(:tenant).find_each do |credential|
      tenant = credential.tenant

      unless DataSourceConfig.source_for(tenant, "freight") == "lucrofrete"
        puts "Pulando tenant=#{tenant.slug}: freight source nao esta configurado como lucrofrete."
        next
      end

      tenant_since = since_date || infer_since.call(tenant)
      unless tenant_since
        puts "Pulando tenant=#{tenant.slug}: informe SINCE=YYYY-MM-DD ou tenha pedidos Yampi locais para inferir o inicio."
        next
      end

      puts "Iniciando backfill LucroFrete tenant=#{tenant.slug} periodo=#{tenant_since}..#{until_date} per_page=#{per_page}."
      puts "O servico respeitara sleep obrigatorio de 60s entre paginas no modo backfill."

      result = Integrations::Lucrofrete::OrdersSyncService.call(
        credential,
        mode: "backfill",
        start_date: tenant_since,
        end_date: until_date,
        per_page: per_page,
        trigger: "rake"
      )
      metadata = result.metadata.with_indifferent_access

      puts "Concluido tenant=#{tenant.slug} outcome=#{result.outcome} " \
        "pages=#{metadata[:pages_processed]}/#{metadata[:total_pages] || '?'} " \
        "matched=#{metadata[:matched_count]} updated=#{metadata[:updated_count]} " \
        "not_found=#{metadata[:not_found_count]} unmatched=#{metadata[:unmatched_count]} " \
        "errors=#{metadata[:error_count]} sleep=#{metadata[:actual_sleep_seconds]}s"
    end
  end
end
