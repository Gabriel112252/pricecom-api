# Read-only diagnóstico pro bug report de 2026-08-17 (kits que continuam
# aparecendo como linha própria em "Giro real de produtos"/"SKUs reais
# vendidos" em vez de explodir nos componentes reais).
#
# Achado por análise de código (não requer produção pra confirmar — ver
# Products::ExplodeKit/Products::TopRealSkusSold):
#   - products.is_kit: false          -> item conta como produto avulso
#     normal, aparece como sua própria linha com a quantidade real do
#     order_item. É EXATAMENTE o sintoma reportado (KIT044 etc. aparecendo
#     como linha própria com quantidade real, não zerada).
#   - products.is_kit: true SEM nenhum KitComponent cadastrado -> Explode
#     Kit retorna [] pra esse item — a venda inteira desaparece do
#     ranking (nem linha própria, nem componentes). Comportamento mantido
#     como está (não é o bug reportado, mas reportado aqui do mesmo jeito
#     — merece registro).
#   - products.is_kit: true COM KitComponent -> explode certo (é o caso
#     que já funciona pra 2080 e outros).
#
# Este task não decide nada sozinho — só lista, pra decisão humana:
# 1) produtos com nome/SKU sugerindo kit (ou is_kit já true) e o estado de
#    cadastro de cada um;
# 2) grupos de nomes idênticos com SKUs diferentes (possível duplicidade
#    de código pro mesmo produto físico, ex: KIT044 x 2133823).
#
#   rails idworks:report_kit_registration_gaps                       # tenant.first, últimos 365 dias
#   TENANT_SLUG=hidrabene DAYS=730 rails idworks:report_kit_registration_gaps
namespace :idworks do
  desc "Diagnóstico read-only: SKUs kit-like sem KitComponent cadastrado + possíveis códigos duplicados pro mesmo produto"
  task report_kit_registration_gaps: :environment do
    kit_name_pattern = /kit|oferta/i
    tenant = ENV["TENANT_SLUG"].present? ? Tenant.find_by!(slug: ENV["TENANT_SLUG"]) : Tenant.first
    abort "Nenhum tenant encontrado." unless tenant

    days = ENV["DAYS"].presence&.to_i || 365
    period = days.days.ago.beginning_of_day..Time.current

    items = OrderItem
      .joins(:order, :product)
      .merge(Order.sales_and_refunds)
      .where(order_id: tenant.orders.where(ordered_at: period).select(:id))
      .where(is_gift: false)

    qty_by_product = items.group("products.id", "products.sku", "products.name", "products.is_kit").sum(:quantity)

    rows = qty_by_product.map do |(id, sku, name, is_kit), qty|
      component_count = is_kit ? KitComponent.where(kit_product_id: id).count : 0
      { id: id, sku: sku, name: name, is_kit: is_kit, component_count: component_count, qty: qty.to_f }
    end

    puts "[#{tenant.slug}] período: últimos #{days} dias (#{period.begin.to_date}..#{period.end.to_date})"
    puts "\n=== 1) SKUs kit-like (nome/SKU sugere kit, ou is_kit já true) — estado de cadastro ==="

    kit_like = rows.select { |r| r[:is_kit] || r[:sku].to_s.match?(kit_name_pattern) || r[:name].to_s.match?(kit_name_pattern) }
      .sort_by { |r| -r[:qty] }

    if kit_like.empty?
      puts "  Nenhum encontrado no período."
    else
      kit_like.each do |r|
        status =
          if r[:is_kit] && r[:component_count] > 0
            "OK — is_kit=true, explode em #{r[:component_count]} componente(s)"
          elsif r[:is_kit]
            "PROBLEMA — is_kit=true mas SEM KitComponent cadastrado (a venda inteira some do ranking)"
          else
            "PROBLEMA — parece kit pelo nome/SKU mas is_kit=false (conta como produto avulso, não explode)"
          end
        puts "  #{r[:sku]} — #{r[:name].inspect} — #{r[:qty]} un. no período — #{status}"
      end
    end

    puts "\n=== 2) Nomes duplicados (SKUs diferentes, mesmo nome — possível código duplicado pro mesmo produto) ==="
    duplicated_names = rows.group_by { |r| r[:name].to_s.strip.downcase }.select { |_, group| group.map { |r| r[:sku] }.uniq.size > 1 }

    if duplicated_names.empty?
      puts "  Nenhum encontrado no período."
    else
      duplicated_names.each do |name, group|
        puts "  #{name.inspect}:"
        group.sort_by { |r| -r[:qty] }.each { |r| puts "    #{r[:sku]} (id=#{r[:id]}, is_kit=#{r[:is_kit]}) — #{r[:qty]} un." }
      end
    end
  end
end
