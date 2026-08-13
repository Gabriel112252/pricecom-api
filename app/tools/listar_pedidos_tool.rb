# frozen_string_literal: true

class ListarPedidosTool < ApplicationTool
  description "Lista pedidos do tenant, com filtro por canal, período e status."

  RESULT_LIMIT = 25

  arguments do
    optional(:canal).filled(:string).description("Nome do canal (ex: yampi, tiktok, shopify)")
    optional(:status).filled(:string).description("Status do pedido (ex: paid, cancelled)")
    optional(:from).filled(:string).description("Data inicial (YYYY-MM-DD)")
    optional(:to).filled(:string).description("Data final (YYYY-MM-DD)")
    optional(:limite).filled(:integer).description("Máximo de pedidos a retornar (padrão 25, máx 25)")
  end

  def call(canal: nil, status: nil, from: nil, to: nil, limite: nil)
    tenant = current_tenant
    return "Usuário sem tenant associado." unless tenant

    scope = tenant.orders.includes(:channel)

    if canal.present?
      channel = tenant.channels.find_by("LOWER(platform) = ?", canal.downcase)
      return "Canal '#{canal}' não encontrado." unless channel

      scope = scope.where(channel_id: channel.id)
    end

    scope = scope.where("LOWER(orders.status) = ?", status.downcase) if status.present?
    scope = scope.where("ordered_at >= ?", parse_date(from)) if from.present?
    scope = scope.where("ordered_at <= ?", parse_date(to).end_of_day) if to.present?

    limit = limite.to_i.positive? ? [ limite.to_i, RESULT_LIMIT ].min : RESULT_LIMIT
    orders = scope.order(ordered_at: :desc).limit(limit)

    { total_no_filtro: scope.count, pedidos: orders.map { |o| order_summary(o) } }
  rescue Date::Error, ArgumentError
    "Data inválida. Use o formato YYYY-MM-DD."
  end

  private

  def parse_date(value)
    Date.parse(value)
  end

  def order_summary(order)
    {
      numero: order.order_number,
      canal: order.channel&.name,
      status: order.status,
      valor_bruto: order.gross_value,
      cliente: order.customer_name,
      data: order.ordered_at
    }
  end
end
