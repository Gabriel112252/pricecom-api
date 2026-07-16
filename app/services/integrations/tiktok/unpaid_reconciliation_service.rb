module Integrations
  module Tiktok
    # Resolve o desfecho dos pedidos TikTok marcados 'unpaid' pela
    # UnpaidOrdersSyncService, re-consultando por ID via Get Order Detail
    # (GET /order/202309/orders):
    #
    #   - virou PAID+ (ON_HOLD..COMPLETED) → reprocessa o payload de detalhe
    #     (atualiza o pedido inteiro, inclusive shipping_fee de auditoria) e
    #     marca o Cart correspondente como converted — a MESMA definição de
    #     "recuperado" do Yampi (Cart#mark_converted!, ver
    #     UpsertOrder#mark_cart_converted);
    #   - CANCELLED → reprocessa (vira order_type cancellation, fora das
    #     métricas) e o cart segue abandoned — abandono definitivo;
    #   - segue UNPAID → mantém e tenta de novo na próxima execução;
    #   - não determinável (sumiu da API, ou ainda unpaid) após
    #     MAX_PENDING_DAYS → orders.status = 'status_unknown' e o pedido sai
    #     da fila de reconsulta para sempre.
    #
    # Antes de gastar API, carts abandonados cujo pedido local JÁ transitou
    # (o polling incremental de pedidos também captura transições de status)
    # são liquidados localmente.
    class UnpaidReconciliationService
      MAX_PENDING_DAYS = 5
      BATCH_SIZE = Integrations::TiktokAdapter::ORDER_DETAIL_MAX_IDS

      # Doc enum pós-pagamento (Get Order List 202309) — allowlist explícita:
      # qualquer status fora dela nunca marca conversão.
      PAID_STATUSES = %w[
        on_hold awaiting_shipment partially_shipping awaiting_collection
        in_transit delivered completed
      ].freeze

      ReconcileEvent = Struct.new(:tenant, :payload, :event_type, :integration, keyword_init: true)

      Result = Struct.new(:outcome, :error_message, :metadata, keyword_init: true) do
        def success? = outcome == :success
        def error? = outcome == :error
        def skipped? = outcome == :skipped
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
        @candidates_count = 0
        @settled_locally_count = 0
        @requeried_count = 0
        @converted_count = 0
        @cancelled_count = 0
        @still_unpaid_count = 0
        @status_unknown_count = 0
        @error_count = 0
        @item_errors = []
      end

      def call
        @log = start_log

        channel = tenant.channels.find_by(platform: "tiktok")
        unless channel
          finish_log(status: "skipped", error_message: "canal tiktok não encontrado")
          return result(:skipped, "canal tiktok não encontrado")
        end

        settle_locally_transitioned_carts(channel)
        reconcile_pending_orders(channel)

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
      rescue => e
        finish_log(status: "error", error_message: e.message)
        result(:error, e.message)
      end

      private

      attr_reader :channel_credential, :tenant, :trigger, :integration, :adapter,
        :started_at, :log, :item_errors

      # Carts tiktok abandonados cujo pedido local já virou PAID+ por outro
      # caminho (o polling incremental também captura transições): converte
      # sem gastar API. Cancelado/status_unknown seguem abandonados — nada a
      # fazer, e ficam fora do join de propósito.
      def settle_locally_transitioned_carts(channel)
        paid_list = PAID_STATUSES.map { |s| ActiveRecord::Base.connection.quote(s) }.join(", ")

        tenant.carts.abandoned.where(channel: channel)
          .joins(<<~SQL.squish)
            INNER JOIN orders ON orders.tenant_id = carts.tenant_id
              AND orders.channel_id = carts.channel_id
              AND orders.external_id = carts.external_id
              AND LOWER(COALESCE(orders.status, '')) IN (#{paid_list})
          SQL
          .find_each do |cart|
            order = tenant.orders.find_by(channel: channel, external_id: cart.external_id)
            next unless order

            cart.mark_converted!(order)
            @settled_locally_count += 1
            @converted_count += 1
          rescue => e
            record_error(cart.external_id, "settle local: #{e.message}")
          end
      end

      def reconcile_pending_orders(channel)
        pending = tenant.orders
          .where(channel: channel)
          .where("LOWER(COALESCE(orders.status, '')) = 'unpaid'")

        @candidates_count = pending.count

        pending.in_batches(of: BATCH_SIZE) do |batch|
          orders = batch.to_a
          details = adapter.fetch_order_details(orders.map(&:external_id)).index_by { |raw| raw["id"].to_s }
          @requeried_count += orders.size

          orders.each { |order| reconcile_order(order, details[order.external_id.to_s], channel) }
        end
      end

      def reconcile_order(order, detail, channel)
        if detail.nil?
          age_out_or_keep(order, reason: "ausente no Get Order Detail")
          return
        end

        remote_status = detail_status(detail)

        if unpaid?(remote_status)
          age_out_or_keep(order, reason: "segue unpaid")
          return
        end

        reprocess(detail)
        order.reload

        if paid_status?(order.status)
          settle_cart(order, channel)
          @converted_count += 1
        elsif cancelled?(order.status)
          @cancelled_count += 1
        else
          age_out_or_keep(order, reason: "status não reconhecido: #{order.status}")
        end
      rescue => e
        record_error(order.external_id, e.message)
      end

      # Reaproveita o pipeline padrão: o payload de detalhe atualiza o
      # pedido inteiro (status, financeiro, shipping_fee de auditoria).
      def reprocess(detail)
        event = ReconcileEvent.new(tenant: tenant, payload: detail, event_type: "order.unpaid_reconciliation", integration: integration)
        processed = Integrations::Processors::TiktokOrderProcessor.call(event)
        raise processed.error_message.to_s if processed.outcome == :error
      end

      def settle_cart(order, channel)
        cart = tenant.carts.find_by(channel: channel, external_id: order.external_id)
        return unless cart
        return if cart.status == "converted" && cart.converted_order_id == order.id

        cart.mark_converted!(order)
      end

      def age_out_or_keep(order, reason:)
        if (order.ordered_at || order.created_at) <= MAX_PENDING_DAYS.days.ago
          order.update!(status: "status_unknown")
          @status_unknown_count += 1
        else
          @still_unpaid_count += 1
        end
      rescue => e
        record_error(order.external_id, "age out (#{reason}): #{e.message}")
      end

      def detail_status(detail)
        detail["status"] || detail["order_status"]
      end

      def unpaid?(status)
        status.to_s.casecmp?("unpaid")
      end

      def paid_status?(status)
        PAID_STATUSES.include?(status.to_s.downcase)
      end

      def cancelled?(status)
        status.to_s.downcase.include?("cancel")
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
          action: "tiktok_unpaid_reconciliation",
          status: "pending",
          started_at: started_at,
          metadata: {
            trigger: trigger,
            channel: "tiktok",
            channel_credential_id: channel_credential.id,
            max_pending_days: MAX_PENDING_DAYS
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
          candidates_count: @candidates_count,
          settled_locally_count: @settled_locally_count,
          requeried_count: @requeried_count,
          converted_count: @converted_count,
          cancelled_count: @cancelled_count,
          still_unpaid_count: @still_unpaid_count,
          status_unknown_count: @status_unknown_count,
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
