# frozen_string_literal: true

class PublicarCadastroProdutoTool < ApplicationTool
  description <<~DESC
    Publica um cadastro já validado. Na Yampi, adiciona a variação/SKU ao
    produto-base existente; se o mesmo SKU já existe no Pricecom em outro
    canal, reutiliza esse Product. A publicação usa a imagem própria do SKU
    resolvida no IDWorks, confirma que a Yampi recebeu imagem e devolve o
    link de compra (purchase_url). AÇÃO DE ESCRITA — exige confirmar: true.
  DESC

  arguments do
    required(:cadastro_id).filled(:integer).description("ID do ProductRegistration")
    required(:confirmar).filled(:bool).description("Precisa ser true para efetivar a publicação")
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
    ).publish!(registration)

    log_activity!(
      action: "product_registration.published",
      target: registration,
      metadata: {
        source: "mcp",
        sku: registration.sku,
        product_id: registration.product_id,
        reused_existing_product: registration.metadata["reused_existing_product"],
        channel_credential_ids: registration.publications.pluck(:channel_credential_id).compact
      }
    )

    result_payload(registration.reload)
  rescue Products::ProductRegistrationService::ValidationError => e
    { erro: "Cadastro não pode ser publicado", validacao: e.errors }
  rescue ActiveRecord::RecordInvalid => e
    { erro: "Falha ao publicar cadastro", validacao: e.record.errors.full_messages }
  end

  private

  def ensure_same_creator(registration)
    return nil if registration.created_by_user_id.blank? || registration.created_by_user_id == current_user.id

    "Este cadastro foi preparado por outro usuário. Gere um novo rascunho no seu próprio contexto MCP."
  end

  def preview_payload(registration)
    image_urls = Array(registration.metadata["source_image_urls"])
    {
      confirmacao_necessaria: true,
      mensagem: "Revise o resumo e chame novamente com confirmar: true. O Pricecom não criará Product duplicado para SKU já existente e a Yampi só será publicada se houver imagem própria da variação.",
      cadastro_id: registration.id,
      status: registration.status,
      sku: registration.sku,
      nome: registration.name,
      preco_centavos: registration.price_cents,
      produto_base: {
        id: registration.parent_product.id,
        sku: registration.parent_product.sku,
        nome: registration.parent_product.name
      },
      produto_pricecom_atual: registration.product && {
        id: registration.product.id,
        sku: registration.product.sku,
        nome: registration.product.name
      },
      imagem_idworks: {
        encontrada: image_urls.any?,
        idworks_id: registration.metadata["source_image_idworks_id"],
        urls: image_urls
      },
      validacao: registration.validation_errors,
      destinos: publication_payloads(registration)
    }
  end

  def result_payload(registration)
    {
      cadastro_id: registration.id,
      status: registration.status,
      reutilizou_produto_pricecom: registration.metadata["reused_existing_product"] == true,
      produto_pricecom: registration.product && {
        id: registration.product.id,
        sku: registration.product.sku,
        nome: registration.product.name
      },
      imagem_idworks: {
        provider: registration.metadata["source_image_provider"],
        idworks_id: registration.metadata["source_image_idworks_id"],
        integracao: registration.metadata["source_image_integration_name"],
        urls: Array(registration.metadata["source_image_urls"])
      }.compact,
      destinos: publication_payloads(registration),
      observacao: external_status_message(registration),
      proximo_passo: registration.publications.any? { |publication| publication.status == "published" } ?
        "O link de compra da Yampi está em destinos[].url_compra. Se precisar reverter o SKU criado por este fluxo, use DesfazerCadastroProdutoTool com este cadastro_id." :
        nil
    }.compact
  end

  def publication_payloads(registration)
    registration.publications.includes(:channel_credential).map do |publication|
      {
        publicacao_id: publication.id,
        canal: publication.channel,
        credencial_canal_id: publication.channel_credential_id,
        loja: publication.channel_credential&.display_name,
        status: publication.status,
        external_product_id: publication.external_product_id,
        external_variant_id: publication.external_variant_id,
        url_compra: publication.metadata["purchase_url"],
        sku_remoto_criado_por_este_fluxo: publication.metadata["remote_sku_created_by_registration"],
        produto_yampi_convertido_de_simples: publication.metadata["converted_product_from_simple"],
        valor_variacao: publication.metadata["variation_value_name"],
        imagens_confirmadas: publication.metadata["remote_images_verified"],
        quantidade_imagens: publication.metadata["remote_image_count"],
        venda_bloqueada_para_revisao: publication.metadata["created_blocked_sale"],
        estoque_inicial: publication.metadata["created_stock_qty"],
        erro_codigo: publication.error_code,
        erro: publication.error_message
      }.compact
    end
  end

  def external_status_message(registration)
    failed = registration.publications.select { |publication| publication.status == "failed" }
    return "Houve falha em parte da publicação; nenhum destino com erro deve ser assumido como concluído." if failed.any?

    waiting = registration.publications.any? { |publication| publication.status == "waiting_connector" }
    return "A Yampi foi processada; há outros destinos aguardando implementação/configuração do publisher externo." if waiting

    "Publicação processada para todos os destinos."
  end
end
