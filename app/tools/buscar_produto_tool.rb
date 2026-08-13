# frozen_string_literal: true

class BuscarProdutoTool < ApplicationTool
  description "Busca produtos por SKU ou nome, com quantidade vendida e receita no período, total e por canal."

  arguments do
    required(:busca).filled(:string).description("SKU ou parte do nome do produto")
    optional(:from).filled(:string).description("Data inicial (YYYY-MM-DD). Padrão: 29 dias atrás.")
    optional(:to).filled(:string).description("Data final (YYYY-MM-DD). Padrão: hoje.")
  end

  # Reaproveita Dashboard::SearchProducts — mesma busca usada no painel
  # "Produtos" do dashboard web.
  def call(busca:, from: nil, to: nil)
    tenant = current_tenant
    return "Usuário sem tenant associado." unless tenant

    result = Dashboard::SearchProducts.call(tenant: tenant, params: { q: busca, from: from, to: to })

    return "Nenhum produto encontrado para '#{busca}'." if result[:results].blank?

    result
  end
end
