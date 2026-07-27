module Integrations
  module Idworks
    # Returns { sku => invoiced_qty } for every SKU faturado no idworks
    # dentro de um período — a metade "fonte de verdade" de
    # Reconciliation::OrderReconciliationService.
    #
    # IMPLEMENTADO 2026-07-27 contra dados reais do tenant hidrabene
    # (hidrabene.api-idworks.com.br) — dois endpoints, casados por
    # idworks_order_id:
    #   - IdworksAdapter#fetch_order_items (GET /orders?SkuView=1) dá as
    #     linhas de SKU/quantidade por pedido, já decompostas em SKU base
    #     pelo próprio idworks (não passa por Products::ExplodeKit/
    #     kit_compositions de novo — decomporia em dobro, ver o comentário
    #     de #fetch_order_items).
    #   - IdworksAdapter#fetch_invoiced_order_ids (GET /invoice, filtrado
    #     por IDOrder em lote) dá quais desses pedidos têm NF emitida
    #     (IDStatusInvoice == 3) — GET /orders não tem nenhum campo de
    #     status de NF, só GET /invoice tem.
    # Pedidos sem NF emitida (rascunho, erro, cancelada) são excluídos
    # antes de somar por SKU.
    class InvoicedQuantityFetcher
      def self.call(*args, **kwargs)
        new.call(*args, **kwargs)
      end

      def call(integration, period_from:, period_to:)
        adapter = IdworksAdapter.new(integration.credentials)
        adapter.authenticate

        items = adapter.fetch_order_items(from: period_from, to: period_to)
        return {} if items.empty?

        invoiced_order_ids = adapter.fetch_invoiced_order_ids(items.map { |i| i[:idworks_order_id] })
        invoiced_items = items.select { |i| invoiced_order_ids.include?(i[:idworks_order_id]) }

        qty_by_sku = Hash.new(0.0)
        invoiced_items.each { |i| qty_by_sku[i[:sku]] += i[:quantity].to_f }
        qty_by_sku
      end
    end
  end
end
