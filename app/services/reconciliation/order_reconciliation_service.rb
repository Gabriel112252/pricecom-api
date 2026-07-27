module Reconciliation
  # Compara, por SKU, a quantidade vendida no Pricecom (order_items dos
  # canais Yampi/TikTok/Shopee, decompondo kits/packs via
  # Products::ExplodeKit) contra a quantidade faturada no idworks (fonte de
  # verdade — nota fiscal única por pedido, ver
  # Integrations::Idworks::InvoicedQuantityFetcher). Persiste um
  # ReconciliationItem por SKU+período (upsert, não histórico) e sincroniza
  # um AuditConflict "order_qty_mismatch" pra cada divergência que estoura
  # o threshold — mesmo padrão de
  # Financials::PagarmePayableSyncService#sync_fee_rate_conflict.
  class OrderReconciliationService
    ORDER_QTY_MISMATCH_CONFLICT_TYPE = "order_qty_mismatch"
    DEFAULT_THRESHOLD_PCT = 5.0

    Result = Struct.new(:outcome, :items_count, :divergent_count, :error_message, :metadata, keyword_init: true) do
      def success? = outcome == :success
      def error?   = outcome == :error
      def skipped? = outcome == :skipped
    end

    def self.call(tenant:, period_from:, period_to:, threshold_pct: DEFAULT_THRESHOLD_PCT,
                   idworks_fetcher: Integrations::Idworks::InvoicedQuantityFetcher)
      new(
        tenant: tenant, period_from: period_from, period_to: period_to,
        threshold_pct: threshold_pct, idworks_fetcher: idworks_fetcher
      ).call
    end

    def initialize(tenant:, period_from:, period_to:, threshold_pct:, idworks_fetcher:)
      @tenant         = tenant
      @period_from    = period_from.to_date
      @period_to      = period_to.to_date
      @threshold_pct  = threshold_pct.to_f
      @idworks_fetcher = idworks_fetcher
      @integration    = tenant.integrations.find_by(provider: "idworks")
    end

    def call
      log = start_log

      unless integration&.status == "connected"
        finish_log(log, status: "skipped", metadata: { reason: "idworks ainda não está conectado" })
        return Result.new(outcome: :skipped, items_count: 0, divergent_count: 0,
                           error_message: "idworks ainda não está conectado", metadata: {})
      end

      idworks_qty_by_sku  = idworks_fetcher.call(integration, period_from: period_from, period_to: period_to)
      pricecom_qty_by_sku = pricecom_qty_by_sku_map

      items = sync_items(idworks_qty_by_sku, pricecom_qty_by_sku)
      divergent = items.select { |item| item.divergent?(threshold_pct) }
      sync_conflicts(items)

      metadata = { items_count: items.size, divergent_count: divergent.size }
      finish_log(log, status: "success", metadata: metadata)

      Result.new(outcome: :success, items_count: items.size, divergent_count: divergent.size,
                 error_message: nil, metadata: metadata)
    rescue Integrations::UnsupportedOperationError, Integrations::AuthenticationError,
           Integrations::ApiError, Integrations::RateLimitError => e
      integration.update!(status: "error") if e.is_a?(Integrations::AuthenticationError)
      finish_log(log, status: "error", metadata: { error: e.message })
      Result.new(outcome: :error, items_count: 0, divergent_count: 0, error_message: e.message, metadata: {})
    end

    private

    attr_reader :tenant, :period_from, :period_to, :threshold_pct, :idworks_fetcher, :integration

    # Nunca inclui a linha do SKU-kit/pack literal (ex: "KIT044", "2080_3")
    # — só os SKUs base reais, que são o que realmente aparece faturado na
    # NF do idworks. Mesma base de Dashboard::BuildSummary#
    # build_product_turnover_summary (app/services/dashboard/build_summary.rb),
    # sem a distinção direct_qty/kit_qty que essa tela usa (aqui só
    # interessa o total real por SKU).
    def pricecom_qty_by_sku_map
      qty_by_sku = Hash.new(0.0)

      items_in_period.where(products: { is_kit: false }).group("products.sku").sum(:quantity).each do |sku, qty|
        qty_by_sku[sku] += qty.to_f
      end

      items_in_period.where(products: { is_kit: true })
        .includes(product: { kit_components: { component_product: { kit_components: :component_product } } })
        .find_each do |item|
          Products::ExplodeKit.call(item.product, item.quantity).each do |leaf|
            qty_by_sku[leaf[:product].sku] += leaf[:real_qty].to_f
          end
        end

      qty_by_sku
    end

    def items_in_period
      OrderItem
        .joins(:order, :product)
        .merge(Order.revenue_countable)
        .where(orders: { tenant_id: tenant.id, ordered_at: period_from.beginning_of_day..period_to.end_of_day })
        .where(is_gift: false)
    end

    def sync_items(idworks_qty_by_sku, pricecom_qty_by_sku)
      skus = (idworks_qty_by_sku.keys + pricecom_qty_by_sku.keys).uniq
      products_by_sku = tenant.products.where(sku: skus).index_by(&:sku)

      skus.map do |sku|
        idworks_qty  = idworks_qty_by_sku[sku].to_f
        pricecom_qty = pricecom_qty_by_sku[sku].to_f
        product      = products_by_sku[sku]

        item = ReconciliationItem.find_or_initialize_by(
          tenant: tenant, sku: sku, period_start: period_from, period_end: period_to
        )
        item.assign_attributes(
          integration:  integration,
          product:      product,
          product_name: product&.name,
          idworks_qty:  idworks_qty,
          pricecom_qty: pricecom_qty,
          diff_qty:     pricecom_qty - idworks_qty,
          diff_pct:     idworks_qty.zero? ? nil : ((pricecom_qty - idworks_qty) / idworks_qty * 100).round(2)
        )
        item.save!
        item
      end
    end

    def sync_conflicts(items)
      items.each { |item| item.divergent?(threshold_pct) ? upsert_conflict(item) : resolve_conflict(item) }
    end

    def find_open_conflict(item)
      AuditConflict
        .where(tenant: tenant, conflict_type: ORDER_QTY_MISMATCH_CONFLICT_TYPE, status: "open")
        .where("metadata ->> 'reconciliation_item_id' = ?", item.id.to_s)
        .first
    end

    def upsert_conflict(item)
      conflict = find_open_conflict(item) || AuditConflict.new(
        tenant: tenant, conflict_type: ORDER_QTY_MISMATCH_CONFLICT_TYPE, status: "open"
      )

      conflict.assign_attributes(
        product:    item.product,
        severity:   item.unmatched_in_idworks? ? "high" : "medium",
        status:     "open",
        source:     "auto",
        expected_value: item.idworks_qty,
        actual_value:   item.pricecom_qty,
        difference:     item.diff_qty,
        metadata: {
          "reconciliation_item_id" => item.id,
          "sku"           => item.sku,
          "period_start"  => item.period_start.iso8601,
          "period_end"    => item.period_end.iso8601,
          "diff_pct"      => item.diff_pct
        }
      )
      conflict.save!
    end

    def resolve_conflict(item)
      conflict = find_open_conflict(item)
      return unless conflict

      conflict.update!(status: "resolved", resolved_at: Time.current)
    end

    def start_log
      IntegrationSyncLog.create!(
        tenant: tenant,
        integration: integration,
        direction: "inbound",
        action: "idworks_reconciliation",
        status: "pending",
        started_at: Time.current,
        metadata: { period_start: period_from.iso8601, period_end: period_to.iso8601, threshold_pct: threshold_pct }
      )
    end

    def finish_log(log, status:, metadata:)
      return unless log

      log.update!(
        status: status,
        finished_at: Time.current,
        duration_ms: ((Time.current - log.started_at) * 1000).round,
        metadata: log.metadata.merge(metadata)
      )
    end
  end
end
