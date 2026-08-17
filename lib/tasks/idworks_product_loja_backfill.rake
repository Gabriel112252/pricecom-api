# One-off: preenche products.integration_id para produtos já sincronizados
# pelo idworks ANTES do tagging em Integrations::Idworks::
# ProductCostSyncService#apply_to_product existir (ver Idworks::
# DashboardStatsService — sem integration_id, o produto conta como "loja
# não identificada" e nunca aparece nos filtros Hidrabene/Anasol).
#
# integration_id não depende de quando o pedido foi feito — é um dado do
# PRODUTO, não do pedido, então este backfill não tem (nem precisa de)
# janela de data: uma vez setado, vale retroativamente pra todo pedido que
# já referencia esse produto.
#
# "Produto já sincronizado pelo idworks" = idworks_id presente (não existe
# products.idworks_synced_at — CostLastPurchase/CostAverage podem ser 0/nil
# e ainda assim o produto ter sido casado com um SKU do idworks).
#
# Não assume qual integração é "Hidrabene" por nome — cada tenant só roda
# se tiver EXATAMENTE UMA integration idworks conectada (hoje é sempre o
# caso; um tenant com Anasol já conectada não pode rodar isto sem
# intervenção manual, porque não dá pra saber por este backfill sozinho
# qual produto pré-existente pertencia a qual das duas).
#
#   rails idworks:backfill_product_loja                 # dry-run — só conta
#   APPLY=1 rails idworks:backfill_product_loja          # aplica de verdade
#   TENANT_SLUG=hidrabene rails idworks:backfill_product_loja  # um tenant só
namespace :idworks do
  desc "Backfill de products.integration_id (loja) para produtos sincronizados pelo idworks antes do tagging existir"
  task backfill_product_loja: :environment do
    apply = ENV["APPLY"] == "1"
    tenants = ENV["TENANT_SLUG"].present? ? [ Tenant.find_by!(slug: ENV["TENANT_SLUG"]) ] : Tenant.all

    puts apply ? "Modo: APLICANDO" : "Modo: DRY-RUN (nada será alterado — rode com APPLY=1 pra aplicar)"

    tenants.each do |tenant|
      integrations = tenant.integrations.where(provider: "idworks")

      if integrations.count != 1
        puts "[#{tenant.slug}] PULADO — #{integrations.count} integration(s) idworks (esperado exatamente 1); rodar manualmente."
        next
      end

      integration = integrations.first
      scope = tenant.products.where(integration_id: nil).where.not(idworks_id: [ nil, "" ])
      count = scope.count

      puts "[#{tenant.slug}] integration=#{integration.name.inspect} (id=#{integration.id}) — produtos a atualizar: #{count}"
      next if count.zero?

      if apply
        updated = scope.update_all(integration_id: integration.id)
        puts "[#{tenant.slug}] atualizados: #{updated}"
      end
    end
  end
end
