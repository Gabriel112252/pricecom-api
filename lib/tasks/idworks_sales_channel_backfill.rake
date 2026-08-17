# Backfill LEVE de orders.idworks_sales_channel pro histórico — não passa
# por Integrations::Idworks::OrderSyncService de propósito (essa classe
# recalcula frete + margem de todo pedido tocado, o que é um risco
# desnecessário só pra taguear um campo de exibição). Aqui é só GET no
# idworks (Integrations::IdworksAdapter#fetch_orders, o mesmo client já
# testado) + Integrations::Idworks::OrderResolver (mesma lógica de match
# do OrderSyncService, extraída pra ser reutilizável) + update_column —
# nunca toca freight/margin/qualquer outro campo do pedido.
#
# Roda em janelas de WINDOW_DAYS (default 7) com uma pausa entre elas —
# IdworksAdapter#fetch_orders já tem retry com backoff pra rate limit por
# página (AdapterHttp#with_rate_limit_retry), isto é só uma cortesia a
# mais pra não martelar a API do idworks numa varredura de meses/anos de
# histórico de uma vez.
#
#   rails idworks:backfill_sales_channel                                  # dry-run, só conta
#   APPLY=1 rails idworks:backfill_sales_channel                          # aplica de verdade
#   TENANT_SLUG=hidrabene FROM=2025-01-01 TO=2026-08-17 rails idworks:backfill_sales_channel
#   WINDOW_DAYS=14 SLEEP_BETWEEN_WINDOWS=1 rails idworks:backfill_sales_channel
namespace :idworks do
  desc "Backfill leve (só leitura na API + update_column) de orders.idworks_sales_channel pro histórico"
  task backfill_sales_channel: :environment do
    apply = ENV["APPLY"] == "1"
    window_days = (ENV["WINDOW_DAYS"].presence || 7).to_i
    sleep_between_windows = (ENV["SLEEP_BETWEEN_WINDOWS"].presence || 0).to_f
    tenants = ENV["TENANT_SLUG"].present? ? [ Tenant.find_by!(slug: ENV["TENANT_SLUG"]) ] : Tenant.all

    puts apply ? "Modo: APLICANDO" : "Modo: DRY-RUN (nada será alterado — rode com APPLY=1 pra aplicar)"

    tenants.each do |tenant|
      integrations = tenant.integrations.where(provider: "idworks")
      if integrations.count != 1
        puts "[#{tenant.slug}] PULADO — #{integrations.count} integration(s) idworks (esperado exatamente 1); rodar manualmente."
        next
      end
      integration = integrations.first

      from = ENV["FROM"].presence ? Time.zone.parse(ENV["FROM"]) : (tenant.orders.minimum(:ordered_at) || 30.days.ago)
      to   = ENV["TO"].presence ? Time.zone.parse(ENV["TO"]) : Time.current

      if from.nil? || to.nil?
        puts "[#{tenant.slug}] PULADO — FROM/TO inválidos."
        next
      end

      adapter  = Integrations::IdworksAdapter.new(integration.credentials)
      adapter.authenticate
      resolver = Integrations::Idworks::OrderResolver.new(tenant: tenant, integration: integration)

      received_count = 0
      matched_count = 0
      unmatched_count = 0
      no_channel_in_payload_count = 0
      updated_count = 0

      window_start = from
      while window_start < to
        window_end = [ window_start + window_days.days, to ].min

        adapter.fetch_orders(from: window_start, to: window_end).each do |raw_order|
          received_count += 1
          resolution = resolver.resolve(raw_order)

          unless resolution[:order]
            unmatched_count += 1
            next
          end

          matched_count += 1
          order = resolution[:order]
          slug = raw_order[:sales_channel_slug]

          if slug.blank?
            no_channel_in_payload_count += 1
            next
          end

          next if order.idworks_sales_channel == slug

          updated_count += 1
          order.update_column(:idworks_sales_channel, slug) if apply
        end

        window_start = window_end
        sleep(sleep_between_windows) if sleep_between_windows.positive? && window_start < to
      end

      puts "[#{tenant.slug}] janela #{from.to_date}..#{to.to_date} — recebidos: #{received_count}, " \
           "casados com pedido Pricecom: #{matched_count}, não casados: #{unmatched_count}, " \
           "sem canal no payload: #{no_channel_in_payload_count}, " \
           "#{apply ? 'atualizados' : 'a atualizar'}: #{updated_count}"
    end
  end
end
