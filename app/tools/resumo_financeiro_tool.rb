# frozen_string_literal: true

class ResumoFinanceiroTool < ApplicationTool
  description "Resumo financeiro do período: receita, pedidos, ticket médio, descontos e vendas por canal."

  arguments do
    optional(:from).filled(:string).description("Data inicial (YYYY-MM-DD). Padrão: 29 dias atrás.")
    optional(:to).filled(:string).description("Data final (YYYY-MM-DD). Padrão: hoje.")
    optional(:canais).filled(:string).description("Nomes de canais separados por vírgula (ex: \"yampi,tiktok\"). Vazio = todos.")
  end

  # Reaproveita Dashboard::BuildSummary — a mesma camada de dados do
  # dashboard web — em vez de duplicar a query. O payload completo dela
  # tem ~25 seções (gráficos, breakdowns, cobertura de dado); devolve só
  # o recorte que faz sentido como resposta de chat, não o payload inteiro.
  def call(from: nil, to: nil, canais: nil)
    tenant = current_tenant
    return "Usuário sem tenant associado." unless tenant

    summary = Dashboard::BuildSummary.call(
      tenant: tenant,
      params: { from: from, to: to, channel_ids: resolve_channel_ids(tenant, canais) }
    )

    {
      periodo: summary[:period],
      kpis: summary[:kpis],
      receita_por_canal: summary[:sales_by_channel],
      financeiro: summary[:financial]
    }
  end

  private

  def resolve_channel_ids(tenant, canais)
    return [] if canais.blank?

    names = canais.to_s.split(",").map { |n| n.strip.downcase }.reject(&:blank?)
    tenant.channels.where("LOWER(platform) IN (?)", names).pluck(:id)
  end
end
