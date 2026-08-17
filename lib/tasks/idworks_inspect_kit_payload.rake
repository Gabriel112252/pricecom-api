# Read-only diagnóstico pro item 2 do pedido de 2026-08-17 (decomposição
# de kit): puxa pedidos reais do idworks que têm pelo menos um item de kit
# (IDSkuKit não-nulo ou KitSkuName presente) e imprime o payload cru
# (sem passar por IdworksAdapter#normalize_order_items, que já descarta
# esses campos) — pra confirmar se o idworks manda os componentes reais
# decompostos como itens separados ou só o SKU do kit com a quantidade de
# kits vendidos.
#
# Evidência já documentada no código (não confirmada de novo por este
# task, mas motivo de este script existir pra checagem independente): ver
# o comentário de fetch_order_items em app/services/integrations/
# idworks_adapter.rb — CONFIRMADO 2026-07-27 contra payload real que os
# itens JÁ vêm decompostos (IDSkuCompany é o SKU base real do componente,
# Quantity já é a quantidade real do componente, não do kit).
#
#   rails idworks:inspect_kit_payload                          # tenant.first, últimos 30 dias
#   TENANT_SLUG=hidrabene DAYS=90 rails idworks:inspect_kit_payload
namespace :idworks do
  desc "Diagnóstico read-only: imprime o payload cru de pedidos com kit (sem normalize_order_items) pra confirmar decomposição"
  task inspect_kit_payload: :environment do
    tenant = ENV["TENANT_SLUG"].present? ? Tenant.find_by!(slug: ENV["TENANT_SLUG"]) : Tenant.first
    abort "Nenhum tenant encontrado." unless tenant

    integrations = tenant.integrations.where(provider: "idworks")
    abort "[#{tenant.slug}] esperado exatamente 1 integration idworks, encontrado #{integrations.count}." if integrations.count != 1
    integration = integrations.first

    client = Integrations::Idworks::BaseClient.new(integration.credentials)
    client.authenticate!

    days = ENV["DAYS"].presence&.to_i || 30
    from = days.days.ago.to_date
    to   = Time.current.to_date

    kit_orders = []
    page = 0

    loop do
      body = client.get("orders", "Page" => page, "SkuView" => 1, "DateFrom" => from.iso8601, "DateTo" => to.iso8601)
      orders = body.is_a?(Array) ? body : (body["Data"] || body["data"] || [])
      break if orders.blank?

      orders.each do |order|
        items = Array(order["Items"])
        has_kit_item = items.any? { |item| item["IDSkuKit"].present? || item["KitSkuName"].present? }
        kit_orders << order if has_kit_item
      end

      break if kit_orders.size >= 10 || orders.size < 1 || page > 200

      page += 1
    end

    puts "[#{tenant.slug}] pedidos com item de kit encontrados (page-by-page até 10 ou fim, #{from}..#{to}): #{kit_orders.size}"
    abort "Nenhum pedido com kit no período — aumente DAYS." if kit_orders.empty?

    puts "\n--- payload completo dos pedidos com kit (até 10) ---"
    kit_orders.first(10).each_with_index do |order, i|
      puts "\n[pedido #{i}]"
      puts JSON.pretty_generate(order)
    end
  end
end
