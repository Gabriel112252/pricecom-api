# One-off: reconcilia o histórico de conversão carrinho → pedido da Yampi.
# Ver Integrations::Yampi::CartConversionBackfillService para a estratégia.
#
#   rails yampi:cart_conversion_backfill                       # todos os tenants com credencial Yampi ativa
#   TENANT_SLUG=minha-loja rails yampi:cart_conversion_backfill # um tenant específico
#   SINCE=2026-04-01 rails yampi:cart_conversion_backfill       # janela manual (default: carrinho abandonado mais antigo)
namespace :yampi do
  desc "Backfill de cart_token nos pedidos Yampi + marca Carts históricos como converted"
  task cart_conversion_backfill: :environment do
    since = ENV["SINCE"].present? ? Time.zone.parse(ENV["SINCE"]) : nil

    credentials = ChannelCredential.active.where(channel: "yampi")
    if ENV["TENANT_SLUG"].present?
      tenant = Tenant.find_by!(slug: ENV["TENANT_SLUG"])
      credentials = credentials.where(tenant: tenant)
    end

    abort "Nenhuma credencial Yampi ativa encontrada." if credentials.none?

    credentials.find_each do |credential|
      slug = credential.tenant.slug
      puts "[#{slug}] iniciando backfill de conversão de carrinhos..."

      result = Integrations::Yampi::CartConversionBackfillService.call(credential, since: since)

      if result.success?
        puts "[#{slug}] OK — pedidos varridos: #{result.orders_scanned}, " \
             "cart_token gravado: #{result.orders_token_updated}, " \
             "carrinhos checados: #{result.carts_checked}, " \
             "convertidos: #{result.carts_converted}"
      else
        puts "[#{slug}] ERRO — #{result.error_message} " \
             "(pedidos varridos: #{result.orders_scanned}, convertidos até o erro: #{result.carts_converted})"
      end
    end
  end
end
