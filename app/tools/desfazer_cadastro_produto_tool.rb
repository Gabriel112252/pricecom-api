# frozen_string_literal: true

class DesfazerCadastroProdutoTool < ApplicationTool
  description <<~DESC
    Desfaz um cadastro criado pelo fluxo guiado. Para variação Yampi, remove
    apenas o SKU criado por este fluxo. Para `produto_simples`, remove o
    produto Yampi inteiro somente se ele foi criado por este cadastro e ainda
    não possui pedidos; produto remoto adotado é preservado. Depois desfaz o
    vínculo local sem apagar Product do Pricecom que já existia em outro canal.
    AÇÃO DESTRUTIVA — exige confirmar: true.
  DESC

  arguments do
    required(:cadastro_id).filled(:integer).description("ID do ProductRegistration a desfazer")
    required(:confirmar).filled(:bool).description("Precisa ser true para remover o que este cadastro criou")
  end

  def call(cadastro_id:, confirmar:)
    admin_error = require_admin!
    return admin_error if admin_error

    tenant = current_tenant
    return "Usuário sem tenant associado." unless tenant

    registration = ProductRegistration
      .where(tenant: tenant)
      .includes(:parent_product, :product, publications: :channel_credential)
      .find_by(id: cadastro_id)
    return "Cadastro #{cadastro_id} não encontrado neste tenant." unless registration

    owner_error = ensure_same_creator(registration)
    return owner_error if owner_error

    unless confirmar
      return preview_payload(registration)
    end

    # O serviço legado de undo conhece o modo variação. Produtos simples são
    # revertidos primeiro aqui; depois o serviço padrão limpa o vínculo local
    # e mantém Products reutilizados por outros canais.
    undo_simple_yampi_publications!(registration)

    registration = Products::ProductRegistrationService.new(
      tenant: tenant,
      user: current_user
    ).undo!(registration.reload)

    log_activity!(
      action: "product_registration.undone",
      target: registration,
      metadata: {
        source: "mcp",
        sku: registration.sku,
        cadastro_id: registration.id
      }
    )

    {
      cadastro_id: registration.id,
      status: registration.status,
      desfeito: true,
      produto_pricecom_id: registration.product_id,
      destinos: registration.publications.includes(:channel_credential).map do |publication|
        {
          canal: publication.channel,
          loja: publication.channel_credential&.display_name,
          modo_publicacao: publication.metadata["publication_mode"],
          status: publication.status,
          ultimo_external_product_id: publication.metadata["last_external_product_id"],
          ultimo_external_variant_id: publication.metadata["last_external_variant_id"],
          resultado_rollback_remoto: publication.metadata["undo_remote_result"],
          desfeito_em: publication.metadata["undone_at"]
        }.compact
      end,
      mensagem: "Cadastro revertido. O rascunho voltou para ready e pode ser publicado novamente depois de revisão."
    }
  rescue Products::ProductRegistrationService::ValidationError => e
    { erro: "Cadastro não pode ser desfeito", validacao: e.errors }
  rescue Products::YampiProductPublicationService::PublicationError => e
    { erro: "Cadastro não pode ser desfeito", validacao: [ e.message ], codigo: e.code }
  rescue ActiveRecord::RecordInvalid => e
    { erro: "Falha ao desfazer cadastro", validacao: e.record.errors.full_messages }
  end

  private

  def ensure_same_creator(registration)
    return nil if registration.created_by_user_id.blank? || registration.created_by_user_id == current_user.id

    "Este cadastro foi preparado por outro usuário e não pode ser desfeito neste contexto MCP."
  end

  def undo_simple_yampi_publications!(registration)
    registration.publications.includes(:channel_credential).each do |publication|
      next unless publication.channel == "yampi"
      next unless publication.metadata["publication_mode"] == Products::YampiSimpleProductPublicationService::PUBLICATION_MODE
      next if publication.external_product_id.blank? && publication.external_variant_id.blank?

      Products::YampiSimpleProductPublicationService.new(
        registration: registration,
        publication: publication
      ).undo!
    end
  end

  def preview_payload(registration)
    {
      confirmacao_necessaria: true,
      mensagem: "Revise cada destino. Em produto_simples, o produto Yampi inteiro só será excluído se este fluxo o criou e se ele ainda não tiver pedidos. Em variação, remove apenas o SKU criado pelo fluxo.",
      cadastro_id: registration.id,
      status: registration.status,
      sku: registration.sku,
      produto_pricecom_id: registration.product_id,
      possui_pedidos_pricecom: registration.product&.order_items&.exists? || false,
      destinos: registration.publications.includes(:channel_credential).map do |publication|
        simple = publication.metadata["publication_mode"] == Products::YampiSimpleProductPublicationService::PUBLICATION_MODE
        {
          canal: publication.channel,
          loja: publication.channel_credential&.display_name,
          modo_publicacao: publication.metadata["publication_mode"] || "variacao",
          status: publication.status,
          external_product_id: publication.external_product_id,
          external_variant_id: publication.external_variant_id,
          url_compra: publication.metadata["purchase_url"],
          acao_remota: if simple
            publication.metadata["remote_product_created_by_registration"] == true ? "excluir_produto_yampi_se_sem_pedidos" : "manter_produto_yampi_adotado"
          else
            publication.metadata["remote_sku_created_by_registration"] == false ? "manter_sku_yampi_adotado" : "excluir_sku_yampi"
          end
        }.compact
      end
    }
  end
end
