# frozen_string_literal: true

class ConsultarCarrinhosTool < ApplicationTool
  description "Consulta carrinhos abandonados ou convertidos por canal e período, com cliente, valores e pedido convertido quando houver."

  RESULT_LIMIT = 50

  arguments do
    optional(:status).filled(:string).description("abandoned ou converted. Padrão: abandoned")
    optional(:canal).filled(:string).description("Canal/plataforma, ex: yampi ou tiktok")
    optional(:from).filled(:string).description("Data inicial YYYY-MM-DD")
    optional(:to).filled(:string).description("Data final YYYY-MM-DD")
    optional(:limite).filled(:integer).description("Máximo de carrinhos. Padrão 25, máximo 50.")
  end

  def call(status: nil, canal: nil, from: nil, to: nil, limite: nil)
    tenant = current_tenant
    return "Usuário sem tenant associado." unless tenant

    cart_status = status.to_s.presence || "abandoned"
    return "Status inválido. Use abandoned ou converted." unless Cart::STATUSES.include?(cart_status)

    scope = tenant.carts.includes(:channel, :converted_order).where(status: cart_status)

    if canal.present?
      scope = scope.joins(:channel).where("LOWER(channels.platform) = ? OR LOWER(channels.name) = ?", canal.downcase, canal.downcase)
    end

    scope = scope.where("carts.abandoned_at >= ?", parse_date(from).beginning_of_day) if from.present?
    scope = scope.where("carts.abandoned_at <= ?", parse_date(to).end_of_day) if to.present?

    max = limite.to_i.positive? ? [ limite.to_i, RESULT_LIMIT ].min : 25
    total = scope.count

    {
      total_no_filtro: total,
      carrinhos: scope.order(abandoned_at: :desc, created_at: :desc).limit(max).map do |cart|
        {
          id: cart.id,
          external_id: cart.external_id,
          token: cart.token,
          canal: cart.channel&.name,
          plataforma: cart.channel&.platform,
          status: cart.status,
          cliente: cart.customer_name,
          email: cart.customer_email,
          subtotal: cart.subtotal,
          desconto: cart.discount,
          desconto_cupom: cart.promocode_discount,
          desconto_progressivo: cart.progressive_discount,
          desconto_combos: cart.combos_discount,
          frete: cart.shipment,
          desconto_frete: cart.shipment_discount,
          total: cart.total,
          abandonado_em: cart.abandoned_at,
          pedido_convertido: cart.converted_order && {
            id: cart.converted_order.id,
            numero: cart.converted_order.order_number,
            status: cart.converted_order.status,
            valor: cart.converted_order.gross_value
          }
        }
      end
    }
  rescue Date::Error, ArgumentError
    "Data inválida. Use o formato YYYY-MM-DD."
  end

  private

  def parse_date(value)
    Date.parse(value)
  end
end
