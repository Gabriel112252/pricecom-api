# frozen_string_literal: true

class CatalogoPricecomTool < ApplicationTool
  description "Mostra o catálogo de dados e ações que a IA pode usar no Pricecom e qual ferramenta usar em cada caso."

  arguments do
  end

  def call
    {
      modo: "leitura_e_escrita_controlada",
      tenant: current_tenant&.name,
      ferramentas: {
        catalogo_pricecom: "Lista as capacidades disponíveis.",
        resumo_financeiro: "KPIs, receita, pedidos, ticket, descontos e vendas por canal em um período.",
        listar_pedidos: "Lista pedidos com filtros por canal, status e período.",
        consultar_pedido: "Detalha um pedido, itens, reembolsos, mappings, IDWorks, conflitos e logs relacionados.",
        buscar_produto: "Busca produto por SKU/nome com vendas e receita no período.",
        consultar_produto_detalhado: "Cadastro, estoque, anúncios/listings, pricing, alertas e vendas recentes de um produto.",
        consultar_produto_omnichannel: "Visão consolidada do mesmo produto/SKU entre os canais conectados.",
        consultar_estoque: "Visão de estoque físico e por canal, reserva livre e alertas ativos.",
        status_sincronizacao_canal: "Status básico das credenciais e pollings dos canais.",
        consultar_integracoes: "Integrações, credenciais sem segredos, fontes de dados, eventos e logs recentes.",
        consultar_operacao: "Fila operacional atual: integrações, estoque, auditoria e anomalias de vendas.",
        consultar_carrinhos: "Carrinhos abandonados/convertidos por canal e período.",
        criar_editar_credencial_canal: "Cria ou substitui uma conexão de loja/canal. Escrita restrita a admin e auditada.",
        vincular_produto_canal: "Vincula um anúncio/SKU remoto já existente ao Product correto no Pricecom. Escrita restrita a admin.",
        alterar_produto_canal: "Altera anúncio/SKU existente usando dados atuais do canal. Escrita restrita a admin e com confirmação quando aplicável.",
        replicar_produto_canal: "Cria produto faltante em um canal usando outro SKU como referência de estrutura. Escrita restrita a admin.",
        criar_cadastro_produto: "Prepara rascunho de nova variação/produto por canal. Exige confirmar:true para criar o rascunho.",
        publicar_cadastro_produto: "Publica um cadastro validado; confirmar:false mantém prévia e confirmar:true efetiva no canal.",
        desfazer_cadastro_produto: "Desfaz o que foi criado pelo fluxo guiado de cadastro, respeitando o tenant e a auditoria."
      },
      dominios_disponiveis: %w[
        dashboard pedidos produtos estoque integracoes operacao auditoria
        financeiro canais carrinhos idworks cadastro_produtos
      ],
      guardrails_escrita: {
        acesso: "As tools de escrita validam usuário/tenant e as operações sensíveis exigem admin.",
        confirmacao: "O fluxo de cadastro separa prévia/rascunho da publicação e exige confirmação explícita para efetivar escrita remota.",
        auditoria: "As ações de escrita registram activity log quando suportado pelo fluxo."
      },
      observacao: "Ferramentas de escrita controlada estão expostas no MCP. Revise a prévia antes de confirmar qualquer publicação ou alteração remota."
    }
  end
end
