# frozen_string_literal: true

class DesfazerCadastroProdutoTool < ApplicationTool
  description <<~DESC
    Desfaz um cadastro de produto criado pelo fluxo guiado: remove da Yampi
    somente os SKUs registrados neste ProductRegistration e, depois que os
    destinos externos forem revertidos, remove o Product local do Pricecom.
    Não executa se o produto já estiver vinculado a pedidos. AÇÃO DESTRUTIVA —
    exige confirmar: true.
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

    registration = Products::ProductRegistrationService.new(
      tenant: tenant,
      user: current_user
    ).undo!(registration)

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
          status: publication.status,
          ultimo_external_product_id: publication.metadata["last_external_product_id"],
          ultimo_external_variant_id: publication.metadata["last_external_variant_id"],
          desfeito_em: publication.metadata["undone_at"]
        }.compact
      end,
      mensagem: "Cadastro revertido. O rascunho voltou para ready e pode ser publicado novamente depois de revisão."
    }
  rescue Products::ProductRegistrationService::ValidationError => e
    { erro: "Cadastro não pode ser desfeito", validacao: e.errors }
  rescue ActiveRecord::RecordInvalid => e
    { erro: "Falha ao desfazer cadastro", validacao: e.record.errors.full_messages }
  end

  private

  def ensure_same_creator(registration)
    return nil if registration.created_by_user_id.blank? || registration.created_by_user_id == current_user.id

    "Este cadastro foi preparado por outro usuário e não pode ser desfeito neste contexto MCP."
  end

  def preview_payload(registration)
    {
      confirmacao_necessaria: true,
      mensagem: "Esta ação removerá da Yampi somente os SKUs externos guardados neste cadastro e, se não houver pedidos vinculados, removerá o Product local. Chame novamente com confirmar: true para prosseguir.",
      cadastro_id: registration.id,
      status: registration.status,
      sku: registration.sku,
      produto_pricecom_id: registration.product_id,
      possui_pedidos: registration.product&.order_items&.exists? || false,
      destinos: registration.publications.includes(:channel_credential).map do |publication|
        {
          canal: publication.channel,
          loja: publication.channel_credential&.display_name,
          status: publication.status,
          external_product_id: publication.external_product_id,
          external_variant_id: publication.external_variant_id,
          url_compra: publication.metadata["purchase_url"]
        }.compact
      end
    }
  end
end
