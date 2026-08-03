# One-off: preenche orders.customer_email para pedidos Yampi importados
# antes do YampiOrderNormalizer capturar esse campo. Reaproveita
# Integrations::Yampi::BackfillOrdersService (idempotente via
# Order#external_id) em vez de tentar ler o payload de integration_events —
# a maioria dos pedidos veio de OrdersPollingService/BackfillOrdersService,
# que nunca persiste o payload bruto (só webhooks fazem isso via
# EventRecorder), então a única forma de recuperar o e-mail é rebuscar da
# API Yampi.
#
#   rails yampi:customer_email_backfill                       # todos os tenants com credencial Yampi ativa
#   TENANT_SLUG=minha-loja rails yampi:customer_email_backfill # um tenant específico
#   DAYS=400 rails yampi:customer_email_backfill               # janela manual (default: desde o pedido Yampi mais antigo do tenant)
namespace :yampi do
  desc "Backfill de customer_email nos pedidos Yampi já importados"
  task customer_email_backfill: :environment do
    credentials = ChannelCredential.active.where(channel: "yampi")
    if ENV["TENANT_SLUG"].present?
      tenant = Tenant.find_by!(slug: ENV["TENANT_SLUG"])
      credentials = credentials.where(tenant: tenant)
    end

    abort "Nenhuma credencial Yampi ativa encontrada." if credentials.none?

    credentials.find_each do |credential|
      slug = credential.tenant.slug
      days = ENV["DAYS"].presence&.to_i || days_since_oldest_yampi_order(credential.tenant)

      if days.nil?
        puts "[#{slug}] sem pedidos Yampi — pulando."
        next
      end

      puts "[#{slug}] iniciando backfill de customer_email (janela: #{days} dias)..."
      result = Integrations::Yampi::BackfillOrdersService.call(credential, days: days)

      if result.success?
        puts "[#{slug}] OK — criados: #{result.created_count}, atualizados: #{result.updated_count}, " \
             "pulados: #{result.skipped.size}"
      else
        puts "[#{slug}] ERRO — #{result.error_message} " \
             "(criados até o erro: #{result.created_count}, atualizados: #{result.updated_count})"
      end
    end
  end

  def days_since_oldest_yampi_order(tenant)
    oldest = tenant.orders.joins(:channel).where(channels: { platform: "yampi" }).minimum(:ordered_at)
    return nil unless oldest

    [ (Time.current - oldest).fdiv(1.day).ceil, 1 ].max
  end
end
