# Read-only diagnóstico pro item pré-requisito do bug report de
# 2026-08-17 (item 3, "canal de venda faltando"): identificar o campo real
# de canal/marketplace/origem no payload de pedido do idworks, ANTES de
# codar o mapeamento em Idworks::DashboardStatsService#channel_breakdown.
#
# Ninguém confirmou esse campo ainda contra um payload real — os únicos
# campos de /orders confirmados até hoje (ver a bateria de comentários
# "CONFIRMED"/"STILL UNVERIFIED" em IdworksAdapter) são Order/IDOrder/
# ValueShipping/ValueProduct/ValueOrder/ValuePaid e, com SkuView=1,
# Recordtimestamp/IDStatusOrder/StatusOrder/Items[]. Nenhum campo de canal
# apareceu em nenhuma captura real até agora — só uma chamada de verdade
# resolve isso, por isso este task chama Integrations::Idworks::BaseClient
# diretamente (mesmo client já testado em produção) em vez de adivinhar um
# nome de campo e arriscar repetir o erro de IDSkuCompany x "Sku" (ver
# IdworksAdapter, comentário de 2026-07-21).
#
# Não altera nada — só GET. Roda no console de quem tem acesso à
# integration idworks já conectada (produção ou staging).
#
#   rails idworks:inspect_order_payload                          # tenant.first, últimos 30 dias
#   TENANT_SLUG=hidrabene DAYS=7 rails idworks:inspect_order_payload
namespace :idworks do
  desc "Diagnóstico read-only: imprime o payload cru (sem normalize_order) de pedidos reais do idworks pra achar o campo de canal/marketplace"
  task inspect_order_payload: :environment do
    channel_like_key_pattern = /canal|channel|marketplace|origem|origin|plataforma|platform|loja|store|market/i
    tenant = ENV["TENANT_SLUG"].present? ? Tenant.find_by!(slug: ENV["TENANT_SLUG"]) : Tenant.first
    abort "Nenhum tenant encontrado." unless tenant

    # Mesmo critério de lookup de idworks_product_loja_backfill.rake —
    # sem filtrar por status: "connected" (o valor real em produção pode
    # não bater com esse literal exato, e isso não deveria decidir se a
    # integration existe ou não). client.authenticate! logo abaixo já
    # falha com uma mensagem clara se as credenciais estiverem inválidas.
    integrations = tenant.integrations.where(provider: "idworks")
    abort "[#{tenant.slug}] esperado exatamente 1 integration idworks, encontrado #{integrations.count}." if integrations.count != 1

    integration = integrations.first

    client = Integrations::Idworks::BaseClient.new(integration.credentials)
    client.authenticate!

    days = ENV["DAYS"].presence&.to_i || 30
    from = days.days.ago.to_date
    to   = Time.current.to_date

    # SkuView=1 pra também inspecionar se o campo de canal vive dentro de
    # Items[] em vez do pedido — ver IdworksAdapter#fetch_order_items.
    body = client.get("orders", "Page" => 0, "SkuView" => 1, "DateFrom" => from.iso8601, "DateTo" => to.iso8601)
    orders = body.is_a?(Array) ? body : (body["Data"] || body["data"] || body["Items"] || body["items"] || [])

    puts "[#{tenant.slug}] pedidos recebidos (page 0, #{from}..#{to}): #{orders.size}"
    abort "Nenhum pedido no período — aumente DAYS ou confirme a janela." if orders.empty?

    all_keys = orders.flat_map { |o| o.is_a?(Hash) ? o.keys : [] }.uniq.sort
    puts "\nTodas as chaves vistas no nível do pedido: #{all_keys.join(', ')}"

    candidate_keys = all_keys.select { |k| k.match?(channel_like_key_pattern) }
    if candidate_keys.any?
      puts "\nCandidatas a campo de canal (nome bate com #{channel_like_key_pattern.inspect}):"
      candidate_keys.each do |key|
        distinct_values = orders.filter_map { |o| o[key] }.uniq
        puts "  #{key.inspect} — valores distintos vistos: #{distinct_values.inspect}"
      end
    else
      puts "\nNenhuma chave no nível do pedido bate com o padrão de canal/marketplace."
    end

    if orders.first["Items"].present?
      item_keys = orders.flat_map { |o| Array(o["Items"]).flat_map { |i| i.is_a?(Hash) ? i.keys : [] } }.uniq.sort
      puts "\nTodas as chaves vistas dentro de Items[]: #{item_keys.join(', ')}"
      item_candidate_keys = item_keys.select { |k| k.match?(channel_like_key_pattern) }
      puts "Candidatas dentro de Items[]: #{item_candidate_keys.presence || 'nenhuma'}"
    end

    puts "\n--- payload completo dos 3 primeiros pedidos (pra inspeção manual) ---"
    orders.first(3).each_with_index do |order, i|
      puts "\n[pedido #{i}]"
      puts JSON.pretty_generate(order)
    end
  end
end
