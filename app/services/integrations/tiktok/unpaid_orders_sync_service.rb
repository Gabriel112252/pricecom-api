module Integrations
  module Tiktok
    # TikTok Shop não expõe carrinho pré-checkout via API — o proxy de
    # "carrinho abandonado" do canal é o pedido criado com status UNPAID.
    # Este service varre POST /order/202309/orders/search com
    # order_status=UNPAID (janela móvel de LOOKBACK_DAYS) e materializa cada
    # pedido em DOIS lugares:
    #
    #   1. orders, via TiktokOrderProcessor/UpsertOrder, com o status
    #      canônico 'unpaid' (Order::NON_REVENUE_STATUSES) — fora de
    #      faturamento/volume/ticket por padrão;
    #   2. carts (channel tiktok), via Integrations::Carts::UpsertCart —
    #      mesma tabela/semântica do checkout Yampi, então o gadget
    #      "Carrinho abandonado" e a definição de "recuperado"
    #      (Cart#status converted + converted_order, ver
    #      UpsertOrder#mark_cart_converted) valem igual nos dois canais.
    #
    # O desfecho do pedido (pagou, cancelou, segue pendente) é resolvido
    # depois pela UnpaidReconciliationService.
    class UnpaidOrdersSyncService
      LOOKBACK_DAYS = 5
      PAGE_SIZE = Integrations::TiktokAdapter::ORDERS_PAGE_SIZE

      SyncEvent = Struct.new(:tenant, :payload, :event_type, :integration, keyword_init: true)

      Result = Struct.new(:outcome, :error_message, :metadata, keyword_init: true) do
        def success? = outcome == :success
        def error? = outcome == :error
        def skipped? = outcome == :skipped
        def rate_limited? = outcome == :rate_limited
      end

      def self.call(channel_credential, trigger: "scheduled")
        new(channel_credential, trigger: trigger).call
      end

      def initialize(channel_credential, trigger: "scheduled")
        @channel_credential = channel_credential
        @tenant = channel_credential.tenant
        @trigger = trigger
        @integration = tenant.integrations.active.find_by(provider: "tiktok")
        @adapter = Integrations::TiktokAdapter.new(channel_credential.credentials)
        @started_at = Time.current
        @window_to = @started_at.utc
        @window_from = @window_to - LOOKBACK_DAYS.days
        @orders_received = 0
        @orders_upserted = 0
        @carts_upserted = 0
        @error_count = 0
        @item_errors = []
      end

      def call
        @log = start_log

        unless channel_credential.polling_enabled?
          finish_log(status: "skipped", error_message: "polling desabilitado")
          return result(:skipped, "polling desabilitado")
        end

        Channel.ensure_for!(tenant, "tiktok")
        fetch_and_process_pages

        if @error_count.positive?
          finish_log(status: "error", error_message: item_errors.first&.fetch(:message, nil))
          return result(:error, item_errors.first&.fetch(:message, nil))
        end

        finish_log(status: "success")
        result(:success, nil)
      rescue Integrations::AuthenticationError => e
        channel_credential.update!(status: "error")
        finish_log(status: "error", error_message: e.message)
        result(:error, e.message)
      rescue Integrations::RateLimitError => e
        finish_log(status: "error", error_message: "rate_limited: #{e.message}")
        result(:rate_limited, e.message)
      rescue => e
        finish_log(status: "error", error_message: e.message)
        result(:error, e.message)
      end

      private

      attr_reader :channel_credential, :tenant, :trigger, :integration, :adapter,
        :started_at, :window_from, :window_to, :log, :item_errors

      def fetch_and_process_pages
        page_token = nil

        loop do
          data = adapter.fetch_orders_page(
            filters: {
              order_status: "UNPAID",
              create_time_ge: window_from.to_i,
              create_time_lt: window_to.to_i
            },
            page_token: page_token,
            page_size: PAGE_SIZE
          )

          orders = data["orders"] || []
          @orders_received += orders.size
          orders.each { |raw_order| process_order(raw_order) }

          page_token = data["next_page_token"]
          break if orders.empty? || page_token.blank?
        end
      end

      def process_order(raw_order)
        event = SyncEvent.new(tenant: tenant, payload: raw_order, event_type: "order.unpaid_polling", integration: integration)
        processed = Integrations::Processors::TiktokOrderProcessor.call(event)

        unless processed.outcome == :success
          return if processed.outcome == :skipped

          record_error(raw_order["id"], processed.error_message || "erro desconhecido")
          return
        end

        @orders_upserted += 1
        upsert_cart(raw_order)
      rescue => e
        record_error(raw_order.is_a?(Hash) ? raw_order["id"] : nil, e.message)
      end

      def upsert_cart(raw_order)
        normalized = Integrations::Normalizers::TiktokOrderNormalizer.new(raw_order, "order.unpaid_polling").normalize
        gross = normalized[:gross_value].to_f
        discount = normalized[:discount].to_f
        freight = normalized[:freight].to_f

        upserted = Integrations::Carts::UpsertCart.call(
          tenant: tenant,
          provider: "tiktok",
          normalized: {
            external_id: normalized[:external_id],
            customer_name: normalized[:customer_name],
            subtotal: gross - freight,
            discount: discount,
            shipment: freight,
            # Identidade do normalizer: gross - discount == total pago pelo
            # comprador — o "valor do pedido UNPAID" que o gadget soma.
            total: gross - discount,
            abandoned_at: normalized[:ordered_at],
            raw: cart_raw_payload(normalized)
          }
        )

        if upserted.success?
          @carts_upserted += 1
        else
          record_error(normalized[:external_id], "cart upsert: #{upserted.error_message}")
        end
      end

      # Shape mínimo que BuildSummary#build_top_abandoned_products sabe ler
      # (array "items" com sku/name/quantity), mais contexto de auditoria.
      def cart_raw_payload(normalized)
        {
          "provider" => "tiktok",
          "source" => "unpaid_order",
          "order_status" => normalized[:status],
          "items" => Array(normalized[:items]).map do |item|
            {
              "sku" => item[:sku],
              "name" => item[:name],
              "quantity" => item[:quantity]
            }
          end
        }
      end

      def record_error(external_id, message)
        @error_count += 1
        item_errors << { external_id: external_id&.to_s, message: message } if item_errors.size < 10
      end

      def start_log
        IntegrationSyncLog.create!(
          tenant: tenant,
          integration: integration,
          direction: "inbound",
          action: "tiktok_unpaid_orders_sync",
          status: "pending",
          started_at: started_at,
          metadata: {
            trigger: trigger,
            channel: "tiktok",
            channel_credential_id: channel_credential.id,
            window_from: window_from.iso8601,
            window_to: window_to.iso8601
          }
        )
      end

      def finish_log(status:, error_message: nil)
        return unless log

        finished_at = Time.current
        log.update!(
          status: status,
          finished_at: finished_at,
          duration_ms: ((finished_at - started_at) * 1000).round,
          error_message: error_message,
          metadata: log.metadata.merge(count_metadata)
        )
      end

      def count_metadata
        {
          orders_received: @orders_received,
          orders_upserted: @orders_upserted,
          carts_upserted: @carts_upserted,
          error_count: @error_count,
          errors: item_errors
        }
      end

      def result(outcome, error_message)
        Result.new(outcome: outcome, error_message: error_message, metadata: count_metadata)
      end
    end
  end
end
