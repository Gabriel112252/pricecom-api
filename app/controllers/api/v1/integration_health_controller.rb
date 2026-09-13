require "sidekiq/api"
require "json"

module Api
  module V1
    class IntegrationHealthController < ApplicationController
      QUEUE_SAMPLE_LIMIT = 1_000
      SNAPSHOT_TTL = 2.hours

      INCIDENT_CATALOG = [
        {
          code: "stokki_rate_limit",
          title: "Stokki limitou as requisições (HTTP 429)",
          severity: "high",
          match: "Stokki 429 / TemporaryError",
          cause: "Volume de chamadas acima do limite observado da Stokki ou concorrência entre poll, webhook e reprocessos manuais.",
          solution: "Aplicar throttling centralizado, retry com backoff e deixar folga para os webhooks. Em backfill manual, reduzir a cadência e retomar somente os não processados.",
          action: "Reduzir taxa e reprocessar pendentes"
        },
        {
          code: "bling_rate_limit",
          title: "Bling limitou as requisições (HTTP 429)",
          severity: "high",
          match: "Bling 429 / TemporaryError",
          cause: "Muitas leituras ou escritas concorrentes na API do Bling.",
          solution: "Usar o RateLimiter do client, evitar consultas repetidas e preferir dados já cacheados no mapping quando possível.",
          action: "Aguardar backoff e reprocessar"
        },
        {
          code: "stokki_order_not_found",
          title: "Pedido não encontrado na Stokki",
          severity: "medium",
          match: "Pedido nao encontrado",
          cause: "O number_erp consultado pode estar ausente, antigo ou incorreto. O erro não prova que o pedido não existe na Stokki.",
          solution: "Validar stokki_number_erp / bling_order_number antes de concluir inexistência. Para pedidos antigos, preencher o ERP a partir do pedido correspondente no Bling.",
          action: "Validar ERP e consultar novamente"
        },
        {
          code: "missing_erp_number",
          title: "Pedido antigo sem number_erp cacheado",
          severity: "medium",
          match: "MissingNumberErpError / stokki_number_erp vazio",
          cause: "Pedidos anteriores à persistência do número do pedido do Bling ficaram somente com bling_id/integration_id.",
          solution: "Cruzar o bling_id com pedidos do Bling em lote e preencher bling_order_number e stokki_number_erp no mapping.",
          action: "Executar backfill de ERP"
        },
        {
          code: "yampi_invoiced_stale",
          title: "Yampi faturado com status/rastreio defasado",
          severity: "high",
          match: "Faturado sem tracking / Stokki já enviado",
          cause: "A expedição avançou na Stokki, mas o retorno para a Yampi não foi aplicado ou ficou preso em fila antiga.",
          solution: "Consultar a Stokki pelo number_erp e aplicar status + track_code na Yampi somente quando houver avanço; nunca regredir status.",
          action: "Sincronizar Stokki → Yampi"
        },
        {
          code: "stokki_webhook_without_erp",
          title: "Webhook Stokki sem number_erp",
          severity: "medium",
          match: "Webhook sem number_erp",
          cause: "Alguns webhooks carregam status/rastreio suficientes para atualizar a Yampi, mas não trazem o number_erp usado pelo fluxo antigo.",
          solution: "Usar diretamente status_id, tracking e tracking_url do payload do webhook para atualizar a Yampi sem consultar Bling ou Stokki novamente.",
          action: "Processar payload direto"
        },
        {
          code: "sidekiq_backlog_duplicates",
          title: "Fila Sidekiq crescendo / jobs duplicados",
          severity: "critical",
          match: "Fila alta, latency crescente ou duplicate_jobs > 0",
          cause: "Poll, webhook e sync podem disputar a mesma fila e reenfileirar o mesmo mapping repetidamente.",
          solution: "Deduplicar enqueue, priorizar jobs interativos/webhook, separar filas quando necessário e aumentar concorrência somente com rate limit centralizado.",
          action: "Deduplicar e revisar filas"
        }
      ].freeze

      def index
        return render json: operational_runtime if params[:runtime].present?

        integrations = current_tenant.integrations.active.includes(:channel)
        render json: integrations.map { |i| health_json(i) }
      end

      private

      def operational_runtime
        queues = sidekiq_queues
        previous = Rails.cache.read(snapshot_cache_key)
        captured_at = Time.current

        queues.each do |queue|
          queue[:growth_per_minute] = queue_growth_per_minute(queue, previous, captured_at)
        end

        Rails.cache.write(
          snapshot_cache_key,
          {
            captured_at: captured_at.iso8601,
            queues: queues.index_by { |queue| queue[:name] }.transform_values { |queue| queue[:size] }
          },
          expires_in: SNAPSHOT_TTL
        )

        processes = Sidekiq::ProcessSet.new.to_a
        busy = Sidekiq::WorkSet.new.size

        {
          captured_at: captured_at,
          processing: {
            total_enqueued: queues.sum { |queue| queue[:size] },
            retry_count: Sidekiq::RetrySet.new.size,
            dead_count: Sidekiq::DeadSet.new.size,
            scheduled_count: Sidekiq::ScheduledSet.new.size,
            processes: processes.size,
            concurrency: processes.sum { |process| process["concurrency"].to_i },
            busy: busy,
            queues: queues
          },
          incidents: INCIDENT_CATALOG
        }
      rescue RedisClient::Error, Sidekiq::RedisConnectionError => error
        {
          captured_at: Time.current,
          processing: {
            available: false,
            error: error.message,
            total_enqueued: 0,
            retry_count: 0,
            dead_count: 0,
            scheduled_count: 0,
            processes: 0,
            concurrency: 0,
            busy: 0,
            queues: []
          },
          incidents: INCIDENT_CATALOG
        }
      end

      def sidekiq_queues
        Sidekiq::Queue.all.map do |queue|
          duplicates = duplicate_stats(queue)

          {
            name: queue.name,
            size: queue.size,
            latency_seconds: queue.latency.to_f.round(1),
            duplicate_jobs: duplicates[:duplicate_jobs],
            duplicate_groups: duplicates[:duplicate_groups],
            sampled_jobs: duplicates[:sampled_jobs]
          }
        end.sort_by { |queue| -queue[:size] }
      end

      def duplicate_stats(queue)
        signatures = Hash.new(0)
        sampled = 0

        queue.each do |job|
          break if sampled >= QUEUE_SAMPLE_LIMIT

          signature = JSON.generate([ job.klass.to_s, job.args ])
          signatures[signature] += 1
          sampled += 1
        rescue StandardError
          sampled += 1
        end

        groups = signatures.values.select { |count| count > 1 }

        {
          sampled_jobs: sampled,
          duplicate_groups: groups.size,
          duplicate_jobs: groups.sum { |count| count - 1 }
        }
      end

      def queue_growth_per_minute(queue, previous, captured_at)
        return nil unless previous.is_a?(Hash)

        previous_at = Time.zone.parse(previous[:captured_at].to_s) rescue nil
        previous_size = previous.dig(:queues, queue[:name])
        return nil unless previous_at && previous_size

        minutes = (captured_at - previous_at) / 60.0
        return nil if minutes <= 0

        ((queue[:size].to_i - previous_size.to_i) / minutes).round(2)
      end

      def snapshot_cache_key
        "operations:sidekiq_snapshot:tenant:#{current_tenant.id}"
      end

      def health_json(integration)
        since_24h = 24.hours.ago

        events_scope = current_tenant.integration_events
                         .where(integration_id: integration.id)
        logs_scope   = current_tenant.integration_sync_logs
                         .where(integration_id: integration.id)

        last_event_at         = events_scope.maximum(:created_at)
        last_event_error_at   = events_scope.where(status: "error").maximum(:updated_at)
        last_success_at       = logs_scope.where(status: "success").maximum(:finished_at)
        last_error_at         = logs_scope.where(status: "error").maximum(:finished_at)
        events_pending_count  = events_scope.where(status: "pending").count
        events_error_count    = events_scope.where(status: "error").count
        logs_success_last_24h = logs_scope.where(status: "success")
                                          .where("created_at >= ?", since_24h).count
        logs_error_last_24h   = logs_scope.where(status: "error")
                                          .where("created_at >= ?", since_24h).count

        {
          id:                    integration.id,
          provider:              integration.provider,
          name:                  integration.name,
          status:                integration.status,
          channel_id:            integration.channel_id,
          channel_name:          integration.channel&.name,
          last_synced_at:        integration.last_synced_at,
          last_event_at:         last_event_at,
          last_event_error_at:   last_event_error_at,
          last_success_at:       last_success_at,
          last_error_at:         last_error_at,
          events_pending_count:  events_pending_count,
          events_error_count:    events_error_count,
          logs_success_last_24h: logs_success_last_24h,
          logs_error_last_24h:   logs_error_last_24h,
          health_status:         resolve_health_status(
            events_pending_count: events_pending_count,
            last_success_at:      last_success_at,
            last_error_at:        last_error_at,
            last_event_error_at:  last_event_error_at
          )
        }
      end

      def resolve_health_status(events_pending_count:, last_success_at:, last_error_at:, last_event_error_at:)
        latest_failure_at = [ last_error_at, last_event_error_at ].compact.max

        if latest_failure_at.present? && (last_success_at.blank? || latest_failure_at > last_success_at)
          return "error"
        end

        return "pending" if events_pending_count > 0
        return "healthy" if last_success_at.present?
        "idle"
      end
    end
  end
end
