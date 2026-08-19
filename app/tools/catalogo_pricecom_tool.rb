# frozen_string_literal: true

class CatalogoPricecomTool < ApplicationTool
  description "Mostra o catálogo de dados que a IA pode consultar no Pricecom e qual ferramenta usar em cada caso."

  arguments do
  end

  def call
    {
      modo: "somente_leitura",
      tenant: current_tenant&.name,
      ferramentas: {
        catalogo_pricecom: "Lista as capacidades de consulta disponíveis.",
        resumo_financeiro: "KPIs, receita, pedidos, ticket, descontos e vendas por canal em um período.",
        listar_pedidos: "Lista pedidos com filtros por canal, status e período.",
        consultar_pedido: "Detalha um pedido, itens, reembolsos, mappings, IDWorks, conflitos e logs relacionados.",
        buscar_produto: "Busca produto por SKU/nome com vendas e receita no período.",
        consultar_produto_detalhado: "Cadastro, estoque, anúncios/listings, pricing, alertas e vendas recentes de um produto.",
        consultar_estoque: "Visão de estoque físico e por canal, reserva livre e alertas ativos.",
        status_sincronizacao_canal: "Status básico das credenciais e pollings dos canais.",
        consultar_integracoes: "Integrações, credenciais sem segredos, fontes de dados, eventos e logs recentes.",
        consultar_operacao: "Fila operacional atual: integrações, estoque, auditoria e anomalias de vendas.",
        consultar_carrinhos: "Carrinhos abandonados/convertidos por canal e período."
      },
      dominios_disponiveis: %w[
        dashboard pedidos produtos estoque integracoes operacao auditoria
        financeiro canais carrinhos idworks
      ],
      observacao: "Ferramentas de escrita existem no código, mas não estão expostas nesta fase do MCP."
    }
  end
end
