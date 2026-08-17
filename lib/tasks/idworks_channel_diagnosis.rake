# Read-only diagnóstico do item 3 do bug report de 2026-08-17: "Vendas por
# canal" da aba idworks só mostra TikTok Shop e Yampi. Idworks::
# DashboardStatsService#channel_breakdown não tem nenhum canal hardcoded —
# agrupa por channels.name de scoped_orders sem filtrar platform — então a
# hipótese mais provável é ausência real de pedido Mercado Livre/Shopee no
# período, não bug de mapeamento. Este task só lê, não altera nada; roda em
# produção sem risco.
#
#   rails idworks:diagnose_channel_breakdown                        # últimos 30 dias, todos os tenants
#   TENANT_SLUG=hidrabene DAYS=30 rails idworks:diagnose_channel_breakdown
namespace :idworks do
  desc "Diagnóstico read-only: pedidos por canal no período (bruto x após Order.sales_and_refunds)"
  task diagnose_channel_breakdown: :environment do
    days = ENV["DAYS"].presence&.to_i || 30
    period = days.days.ago.beginning_of_day..Time.current
    tenants = ENV["TENANT_SLUG"].present? ? [ Tenant.find_by!(slug: ENV["TENANT_SLUG"]) ] : Tenant.all

    tenants.each do |tenant|
      puts "== #{tenant.slug} (últimos #{days} dias) =="

      raw_counts = tenant.orders.joins(:channel).where(ordered_at: period).group("channels.name").count
      scoped_counts = tenant.orders.joins(:channel).where(ordered_at: period).merge(Order.sales_and_refunds).group("channels.name").count

      Channel::PLATFORMS.each do |platform|
        channel_names = tenant.channels.where(platform: platform).pluck(:name)
        if channel_names.empty?
          puts "  #{platform}: nenhum Channel cadastrado pra esse tenant"
          next
        end

        channel_names.each do |name|
          puts "  #{platform} (#{name}): #{raw_counts[name] || 0} pedido(s) no período bruto, " \
               "#{scoped_counts[name] || 0} após Order.sales_and_refunds (o que idworks_dashboard usa)"
        end
      end
    end
  end
end
