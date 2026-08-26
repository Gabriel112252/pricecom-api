# frozen_string_literal: true

class ConsultarProdutoOmnichannelTool < ApplicationTool
  description <<~DESC
    Consulta um produto/SKU AO VIVO em Pricecom, IDWorks, Yampi e TikTok.
    Retorna preços, estoque, IDs externos, URLs, imagens, anúncios do Hub IDWorks,
    duplicidades, vínculos locais e divergências. Use esta tool antes de criar,
    vincular, replicar ou alterar um produto para evitar duplicações.
  DESC

  arguments do
    required(:busca).filled(:string).description("SKU, nome exato ou ID interno do Product")
  end

  def call(busca:)
    tenant = current_tenant
    return "Usuário sem tenant associado." unless tenant

    Products::OmnichannelProductInspectorService.new(
      tenant: tenant,
      busca: busca
    ).call
  rescue ArgumentError => e
    { erro: e.message }
  rescue => e
    {
      erro: "Falha ao consultar produto omnichannel",
      error_class: e.class.name,
      detalhe: e.message.to_s.first(500)
    }
  end
end
