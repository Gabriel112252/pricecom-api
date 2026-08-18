# Read-only diagnóstico pro achado de 2026-08-18: idworks:backfill_sales_channel
# processou dezenas de milhares de pedidos vindos da API do idworks mas só
# casou 5 contra Order no Pricecom. Integrations::Idworks::OrderResolver já
# calcula tudo que precisamos pra investigar (candidatos buscados,
# estratégia, quantos bateram) — só que nem OrderSyncService nem o rake task
# de backfill persistem esses detalhes com valores reais (OrderSyncService
# grava em IntegrationSyncLog, mas SHA-256-hasheado via
# IdworksAdapter#anonymized_value; o backfill nem isso, só contadores). Este
# task imprime os valores reais (Order/IDOrder do idworks x order_number/
# external_id do Pricecom) direto no console de quem estiver rodando — não
# escreve nada, não precisa de APPLY.
#
#   TENANT_SLUG=hidrabene DAYS=1 LIMIT=10 rails idworks:diagnose_order_matching
namespace :idworks do
  desc "Diagnóstico read-only: casa uma amostra de pedidos idworks contra o Pricecom e imprime valores reais lado a lado"
  task diagnose_order_matching: :environment do
    tenant = ENV["TENANT_SLUG"].present? ? Tenant.find_by!(slug: ENV["TENANT_SLUG"]) : Tenant.first
    abort "Nenhum tenant encontrado." unless tenant

    integrations = tenant.integrations.where(provider: "idworks")
    abort "[#{tenant.slug}] esperado exatamente 1 integration idworks, encontrado #{integrations.count}." if integrations.count != 1
    integration = integrations.first

    days  = (ENV["DAYS"].presence || 1).to_i
    limit = (ENV["LIMIT"].presence || 10).to_i
    from  = days.days.ago
    to    = Time.current

    adapter  = Integrations::IdworksAdapter.new(integration.credentials)
    adapter.authenticate
    resolver = Integrations::Idworks::OrderResolver.new(tenant: tenant, integration: integration)

    orders = adapter.fetch_orders(from: from, to: to)
    puts "[#{tenant.slug}] #{orders.size} pedidos recebidos do idworks (#{from.to_date}..#{to.to_date})"
    abort "Nenhum pedido no período — aumente DAYS." if orders.empty?

    matched = []
    unmatched = []
    orders.each do |raw_order|
      resolution = resolver.resolve(raw_order)
      if resolution[:order]
        matched << [ raw_order, resolution ]
      else
        unmatched << [ raw_order, resolution ]
      end
    end

    puts "\nResumo: #{matched.size} casados, #{unmatched.size} não casados, de #{orders.size} recebidos"
    puts "Motivos de não-casamento: #{unmatched.map { |_, r| r[:reason] }.tally}"

    puts "\n== CASADOS (mostrando até #{limit} de #{matched.size}) =="
    matched.first(limit).each do |raw_order, resolution|
      order = resolution[:order]
      puts "-" * 70
      puts "idworks: Order=#{raw_order[:order_ref].inspect} IDOrder=#{raw_order[:idworks_order_id].inspect}"
      puts "  -> Pricecom order_id=#{order.id} order_number=#{order.order_number.inspect} " \
           "external_id=#{order.external_id.inspect} channel=#{order.channel&.platform.inspect}"
      puts "  match_source=#{resolution[:match_source]} match_strategy=#{resolution[:match_strategy]} " \
           "search_reference=#{resolution[:search_reference].inspect}"
    end

    puts "\n== NÃO CASADOS (mostrando até #{limit} de #{unmatched.size}) =="
    unmatched.first(limit).each do |raw_order, resolution|
      puts "-" * 70
      puts "idworks: Order=#{raw_order[:order_ref].inspect} IDOrder=#{raw_order[:idworks_order_id].inspect}"
      puts "  raw_keys do payload idworks: #{raw_order[:raw_keys].inspect}"
      puts "  reason=#{resolution[:reason]}"
      Array(resolution[:attempts]).each do |a|
        puts "  tentativa: source=#{a[:source]} strategy=#{a[:strategy]} reference=#{a[:reference].inspect} " \
             "matches_count=#{a[:matches_count]} matched_order_ids=#{a[:matched_order_ids].inspect}"
      end
    end

    puts "\n== AMOSTRA DE PEDIDOS PRICECOM NO MESMO PERÍODO (pra comparar formato, independente de terem casado) =="
    tenant.orders.where(ordered_at: from..to).order(ordered_at: :desc).limit(limit).each do |o|
      puts "  order_id=#{o.id} order_number=#{o.order_number.inspect} external_id=#{o.external_id.inspect} " \
           "channel=#{o.channel&.platform.inspect} ordered_at=#{o.ordered_at}"
    end
  end
end
