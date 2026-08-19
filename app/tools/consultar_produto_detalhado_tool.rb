# frozen_string_literal: true

class ConsultarProdutoDetalhadoTool < ApplicationTool
  description "Consulta cadastro e situação completa de um produto por SKU, nome ou ID: estoque, canais, pricing, kits, alertas e vendas recentes."

  arguments do
    required(:busca).filled(:string).description("SKU, nome ou ID interno do produto")
    optional(:dias).filled(:integer).description("Período de vendas recentes em dias. Padrão 30, máximo 90.")
  end

  def call(busca:, dias: nil)
    tenant = current_tenant
    return "Usuário sem tenant associado." unless tenant

    product = find_exact_product(tenant, busca)
    unless product
      matches = tenant.products
        .where("sku ILIKE :q OR name ILIKE :q", q: "%#{busca}%")
        .order(name: :asc)
        .limit(10)

      return "Nenhum produto encontrado para '#{busca}'." if matches.empty?

      return {
        mensagem: "Mais de um produto encontrado. Refine por SKU ou ID.",
        resultados: matches.map { |p| { id: p.id, sku: p.sku, nome: p.name, ativo: p.active, kit: p.is_kit } }
      }
    end

    period_days = dias.to_i.positive? ? [ dias.to_i, 90 ].min : 30

    {
      produto: product_payload(product),
      estoque: stock_payload(product),
      canais: listings_payload(product),
      pricing: pricing_payload(product),
      kit: kit_payload(product),
      vendas_recentes: sales_payload(tenant, product, period_days),
      alertas_abertos: alerts_payload(product),
      conflitos_abertos: conflicts_payload(product)
    }
  end

  private

  def find_exact_product(tenant, value)
    scope = tenant.products
    scope.find_by(sku: value) ||
      (value.to_s.match?(/\A\d+\z/) ? scope.find_by(id: value.to_i) : nil) ||
      scope.find_by("LOWER(name) = ?", value.to_s.downcase)
  end

  def product_payload(product)
    {
      id: product.id,
      sku: product.sku,
      nome: product.name,
      custo: product.cost_price,
      ativo: product.active,
      kit: product.is_kit,
      idworks_id: product.idworks_id,
      integracao_idworks_origem: product.integration&.name,
      criado_em: product.created_at,
      atualizado_em: product.updated_at
    }
  end

  def stock_payload(product)
    {
      quantidade_disponivel_erp: product.qty_available,
      quantidade_reservada: product.qty_reserved,
      reserva_livre: product.free_reserve,
      estoque_seguranca: product.qty_safety_stock,
      curva_abc: product.abc_curve,
      lead_time_dias: product.lead_time_days,
      estoque_infinito: product.infinite_inventory,
      sincronizado_em: product.stock_synced_at
    }
  end

  def listings_payload(product)
    product.channel_product_listings.order(:channel).map do |listing|
      {
        canal: listing.channel,
        external_id: listing.external_id,
        external_sku: listing.external_sku,
        estoque_no_canal: listing.stock_qty,
        preco: listing.price,
        status_remoto: listing.remote_status,
        motivo_status: listing.remote_status_reason,
        status_venda: listing.selling_status,
        venda_habilitada: listing.selling_enabled,
        elegivel_reposicao: listing.replenishment_eligible,
        sincronizado_em: listing.synced_at,
        status_remoto_sincronizado_em: listing.remote_status_synced_at
      }
    end
  end

  def pricing_payload(product)
    product.pricing_rules.includes(:channel).map do |rule|
      {
        canal: rule.channel&.name,
        margem_alvo_pct: rule.target_margin_pct,
        preco_atual: rule.current_price,
        preco_sugerido: rule.suggested_price,
        calculado_em: rule.last_calculated_at
      }
    end
  end

  def kit_payload(product)
    return { e_kit: false, componentes: [] } unless product.is_kit

    {
      e_kit: true,
      componentes: product.kit_components.includes(:component_product).map do |component|
        {
          sku: component.component_product&.sku,
          nome: component.component_product&.name,
          quantidade: component.quantity
        }
      end
    }
  end

  def sales_payload(tenant, product, days)
    from = days.days.ago.beginning_of_day
    scope = OrderItem
      .joins(:order)
      .merge(Order.sales_and_refunds)
      .where(product_id: product.id, orders: { tenant_id: tenant.id })
      .where("orders.ordered_at >= ?", from)

    {
      periodo_dias: days,
      quantidade_direta: scope.sum(:quantity),
      receita_bruta_itens: scope.sum("order_items.quantity * COALESCE(order_items.unit_price, 0)"),
      pedidos: scope.select(:order_id).distinct.count
    }
  end

  def alerts_payload(product)
    product.stock_alerts
      .where(status: %w[pending awaiting_confirmation insufficient_reserve failed])
      .order(created_at: :desc)
      .limit(10)
      .map do |alert|
        {
          status: alert.status,
          canal: alert.channel,
          quantidade_no_disparo: alert.qty_at_trigger,
          reposicao_sugerida: alert.suggested_replenishment_qty,
          erro: alert.error_message,
          criado_em: alert.created_at
        }
      end
  end

  def conflicts_payload(product)
    product.audit_conflicts.open.where.not(conflict_type: "missing_cost").order(created_at: :desc).limit(10).map do |conflict|
      {
        tipo: conflict.conflict_type,
        severidade: conflict.severity,
        pedido_id: conflict.order_id,
        metadata: conflict.metadata,
        criado_em: conflict.created_at
      }
    end
  end
end
