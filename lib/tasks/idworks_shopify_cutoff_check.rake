# Read-only: valida a premissa por trás do corte de data shopify -> Yampi
# em Idworks::DashboardStatsService (SHOPIFY_TO_YAMPI_CUTOFF =
# 2026-06-15) — conta pedidos com orders.idworks_sales_channel = "shopify"
# antes e a partir dessa data. Se a migração Shopify -> Yampi foi
# completa, não deveria sobrar volume relevante de "shopify" pós-corte;
# volume relevante ali é sinal de que a data ou a premissa está errada —
# reportar antes de confiar no mapeamento.
#
# Só enxerga pedidos que já passaram por
# Integrations::Idworks::OrderSyncService (orders.idworks_sales_channel
# só é preenchido por esse sync, gated por DataSourceConfig "freight" ->
# "idworks" — ver comentário da classe). Rode uma sincronização recente
# antes de tirar conclusões se o número total vier muito menor do que o
# volume real de pedidos do período.
#
#   rails idworks:shopify_cutoff_check
#   TENANT_SLUG=hidrabene rails idworks:shopify_cutoff_check
namespace :idworks do
  desc "Diagnóstico read-only: conta pedidos idworks_sales_channel=shopify antes/depois do corte de 2026-06-15"
  task shopify_cutoff_check: :environment do
    cutoff = Idworks::DashboardStatsService::SHOPIFY_TO_YAMPI_CUTOFF.beginning_of_day
    tenants = ENV["TENANT_SLUG"].present? ? [ Tenant.find_by!(slug: ENV["TENANT_SLUG"]) ] : Tenant.all

    tenants.each do |tenant|
      scope = tenant.orders.where(idworks_sales_channel: "shopify")
      before = scope.where(ordered_at: ...cutoff).count
      from_cutoff = scope.where(ordered_at: cutoff..).count
      tagged_total = tenant.orders.where.not(idworks_sales_channel: nil).count

      puts "[#{tenant.slug}] pedidos com idworks_sales_channel já preenchido: #{tagged_total}"
      puts "[#{tenant.slug}] shopify antes de #{cutoff.to_date} (exclusive): #{before}"
      puts "[#{tenant.slug}] shopify a partir de #{cutoff.to_date} (inclusive) — deveria ser ~0 se a migração pra Yampi foi completa: #{from_cutoff}"
    end
  end
end
