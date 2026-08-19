# frozen_string_literal: true

class ConsultarEstoqueTool < ApplicationTool
  description "Consulta estoque físico e por canal, reserva livre e alertas ativos. Pode filtrar por SKU/nome e canal."

  RESULT_LIMIT = 50

  arguments do
    optional(:busca).filled(:string).description("SKU ou parte do nome do produto")
    optional(:canal).filled(:string).description("Canal/listing (ex: yampi, tiktok, shopee)")
    optional(:somente_com_alerta).filled(:string).description("Use 'sim' para retornar apenas produtos com alerta de estoque ativo")
    optional(:limite).filled(:integer).description("Máximo de produtos. Padrão 25, máximo 50.")
  end

  def call(busca: nil, canal: nil, somente_com_alerta: nil, limite: nil)
    tenant = current_tenant
    return "Usuário sem tenant associado." unless tenant

    scope = tenant.products.includes(:channel_product_listings, :stock_alerts)
    scope = scope.where("products.sku ILIKE :q OR products.name ILIKE :q", q: "%#{busca}%") if busca.present?

    if canal.present?
      scope = scope.joins(:channel_product_listings)
        .where("LOWER(channel_product_listings.channel) = ?", canal.downcase)
        .distinct
    end

    if somente_com_alerta.to_s.downcase == "sim"
      scope = scope.joins(:stock_alerts)
        .where(stock_alerts: { status: %w[pending awaiting_confirmation insufficient_reserve failed] })
        .distinct
    end

    total = scope.count
    max = limite.to_i.positive? ? [ limite.to_i, RESULT_LIMIT ].min : 25
    products = scope.order(:name).limit(max)

    {
      total_no_filtro: total,
      produtos: products.map { |product| payload(product, canal) }
    }
  end

  private

  def payload(product, canal)
    listings = product.channel_product_listings
    listings = listings.select { |listing| listing.channel.to_s.casecmp?(canal) } if canal.present?

    {
      id: product.id,
      sku: product.sku,
      nome: product.name,
      ativo: product.active,
      estoque_erp: product.qty_available,
      reservado: product.qty_reserved,
      reserva_livre: product.free_reserve,
      estoque_seguranca: product.qty_safety_stock,
      curva_abc: product.abc_curve,
      lead_time_dias: product.lead_time_days,
      estoque_infinito: product.infinite_inventory,
      sincronizado_em: product.stock_synced_at,
      canais: listings.map do |listing|
        {
          canal: listing.channel,
          external_sku: listing.external_sku,
          estoque: listing.stock_qty,
          preco: listing.price,
          status_venda: listing.selling_status,
          venda_habilitada: listing.selling_enabled,
          elegivel_reposicao: listing.replenishment_eligible,
          sincronizado_em: listing.synced_at
        }
      end,
      alertas_ativos: product.stock_alerts
        .select { |alert| %w[pending awaiting_confirmation insufficient_reserve failed].include?(alert.status) }
        .sort_by(&:created_at)
        .reverse
        .first(5)
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
    }
  end
end
