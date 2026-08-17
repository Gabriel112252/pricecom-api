class AddIdworksSalesChannelToOrders < ActiveRecord::Migration[7.2]
  def change
    # Canal nativo do idworks (extraído do filename de SalesChannelLogoUrl
    # no payload de /orders — confirmado 2026-08-17: "shopify"/"tiktok"/
    # "shopee"/"mercadolivre"). Só a aba idworks usa isto (Idworks::
    # DashboardStatsService#channel_breakdown) — as outras abas continuam
    # com channels.platform (a integração própria do Pricecom), que não
    # cobre canais sem integração direta (ex: Mercado Livre). Ver
    # Integrations::Idworks::OrderSyncService#apply_sales_channel.
    add_column :orders, :idworks_sales_channel, :string
    add_index :orders, :idworks_sales_channel
  end
end
