# frozen_string_literal: true

class ConsultarPedidoTool < ApplicationTool
  description "Consulta um pedido em profundidade por número, external_id ou ID interno: valores, itens, NF, reembolsos, mappings, presença na IDWorks, conflitos e logs recentes."

  arguments do
    required(:pedido).filled(:string).description("Número do pedido, external_id ou ID interno do Pricecom")
  end

  def call(pedido:)
    tenant = current_tenant
    return "Usuário sem tenant associado." unless tenant

    order = find_order(tenant, pedido)
    return "Pedido '#{pedido}' não encontrado no Pricecom." unless order

    {
      pedido: order_payload(order),
      itens: order.order_items.map { |item| item_payload(item) },
      reembolsos: order.order_refunds.map { |refund| refund_payload(refund) },
      mappings: order.integration_mappings.map { |mapping| mapping_payload(mapping) },
      idworks: idworks_payload(tenant, order),
      conflitos_abertos: conflicts_payload(order),
      logs_recentes: logs_payload(tenant, order)
    }
  end

  private

  def find_order(tenant, value)
    scope = tenant.orders.includes(
      :channel,
      :order_refunds,
      { order_items: :product },
      { integration_mappings: :integration }
    )

    scope.find_by(order_number: value) ||
      scope.find_by(external_id: value) ||
      (value.to_s.match?(/\A\d+\z/) ? scope.find_by(id: value.to_i) : nil)
  end

  def order_payload(order)
    {
      id: order.id,
      numero: order.order_number,
      external_id: order.external_id,
      canal: order.channel&.name,
      plataforma: order.channel&.platform,
      tipo: order.order_type,
      status: order.status,
      valor_bruto: order.gross_value,
      valor_liquido_apos_reembolso: order.net_gross_value,
      custo: order.cost_price,
      frete_cobrado: order.freight,
      frete_real: order.real_freight_cost,
      desconto: order.discount,
      cupom: order.coupon_code,
      desconto_cupom: order.coupon_discount,
      comissao: order.commission,
      custo_operacional: order.operational_cost,
      margem: order.margin,
      margem_pct: order.margin_pct,
      reembolso: order.refund_amount,
      pagamento: order.payment_method,
      cliente: order.customer_name,
      email_cliente: order.customer_email,
      estado: order.state,
      quantidade_itens: order.items_qty,
      nota_fiscal: {
        numero: order.nf_number,
        valor: order.nf_gross_value,
        desconto: order.nf_discount,
        frete: order.nf_freight
      },
      financeiro_tiktok: {
        sincronizado_em: order.financial_synced_at,
        receita: order.revenue_amount,
        repasse: order.settlement_amount,
        taxas_e_impostos: order.fee_and_tax_amount,
        custo_frete: order.shipping_cost_amount,
        comissao_plataforma: order.platform_commission_amount,
        comissao_afiliado: order.affiliate_commission_amount,
        proxima_tentativa: order.financial_next_attempt_at,
        motivo_pendente: order.financial_pending_reason
      },
      criado_em: order.created_at,
      pedido_em: order.ordered_at
    }
  end

  def item_payload(item)
    {
      id: item.id,
      product_id: item.product_id,
      sku: item.sku,
      nome: item.name,
      quantidade: item.quantity,
      preco_unitario: item.unit_price,
      custo_unitario: item.unit_cost,
      desconto: item.discount,
      brinde: item.is_gift,
      preco_unitario_nf: item.nf_unit_price,
      produto_pricecom: item.product && {
        sku: item.product.sku,
        nome: item.product.name,
        idworks_id: item.product.idworks_id
      }
    }
  end

  def refund_payload(refund)
    {
      external_id: refund.external_id,
      valor: refund.amount,
      motivo: refund.reason,
      status: refund.status,
      reembolsado_em: refund.refunded_at
    }
  end

  def mapping_payload(mapping)
    {
      integracao: mapping.integration&.name,
      provider: mapping.integration&.provider,
      external_id: mapping.external_id,
      external_code: mapping.external_code,
      external_type: mapping.external_type,
      status: mapping.status,
      ultima_sincronizacao: mapping.last_synced_at
    }
  end

  def idworks_payload(tenant, order)
    matches = tenant.idworks_orders
      .includes(:integration)
      .where(order_number: order.order_number)
      .or(tenant.idworks_orders.includes(:integration).where(external_id: order.external_id))
      .order(last_seen_at: :desc)
      .limit(10)

    {
      encontrado: matches.exists?,
      registros: matches.map do |record|
        {
          integracao: record.integration&.name,
          external_id: record.external_id,
          numero: record.order_number,
          status: record.status_order,
          status_id: record.id_status_order,
          canal_venda: record.sales_channel_slug,
          valor_produtos: record.value_product,
          frete: record.value_shipping,
          valor_pedido: record.value_order,
          valor_pago: record.value_paid,
          registrado_em: record.recorded_at,
          visto_em: record.last_seen_at
        }
      end
    }
  end

  def conflicts_payload(order)
    order.audit_conflicts.open.where.not(conflict_type: "missing_cost").order(created_at: :desc).map do |conflict|
      {
        tipo: conflict.conflict_type,
        severidade: conflict.severity,
        esperado: conflict.expected_value,
        atual: conflict.actual_value,
        diferenca: conflict.difference,
        metadata: conflict.metadata,
        criado_em: conflict.created_at
      }
    end
  end

  def logs_payload(tenant, order)
    ids = [ order.external_id, order.order_number ].compact.map(&:to_s).reject(&:blank?)
    return [] if ids.empty?

    tenant.integration_sync_logs
      .where(external_id: ids)
      .order(created_at: :desc)
      .limit(10)
      .map do |log|
        {
          integracao_id: log.integration_id,
          acao: log.action,
          direcao: log.direction,
          status: log.status,
          erro: log.error_message,
          inicio: log.started_at,
          fim: log.finished_at,
          duracao_ms: log.duration_ms,
          criado_em: log.created_at
        }
      end
  end
end
