# frozen_string_literal: true

class PublicarCadastroProdutoTool < ApplicationTool
  description <<~DESC
    Publica um cadastro já validado. Com confirmar:false, atualiza a prévia
    sem escrever na Yampi: tenta primeiro a imagem própria do SKU no IDWorks
    e, se ela não existir, usa a imagem do produto-base como fallback. Com
    confirmar:true, adiciona a variação/SKU ao produto-base da Yampi,
    reutilizando o mesmo Product do Pricecom quando o SKU já existe em outro
    canal, e devolve purchase_url.
  DESC

  arguments do
    required(:cadastro_id).filled(:integer).description("ID do ProductRegistration")
    required(:confirmar).filled(:bool).description("Use false para prévia atualizada; true para efetivar a publicação")
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
      registration = refresh_preview!(registration)
      return preview_payload(registration)
    end

    registration = registration_service.publish!(registration)

    log_activity!(
      action: "product_registration.published",
      target: registration,
      metadata: {
        source: "mcp",
        sku: registration.sku,
        product_id: registration.product_id,
        reused_existing_product: registration.metadata["reused_existing_product"],
        source_image_sku: registration.metadata["source_image_sku"],
        source_image_fallback_to_parent: registration.metadata["source_image_fallback_to_parent"],
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

  def registration_service
    @registration_service ||= Products::ProductRegistrationService.new(
      tenant: current_tenant,
      user: current_user
    )
  end

  def ensure_same_creator(registration)
    return nil if registration.created_by_user_id.blank? || registration.created_by_user_id == current_user.id

    "Este cadastro foi preparado por outro usuário. Gere um novo rascunho no seu próprio contexto MCP."
  end

  # Prévia é deliberadamente read-only para Yampi. A única escrita é no
  # metadata/status do rascunho Pricecom, para registrar qual imagem foi
  # encontrada no IDWorks e limpar validações antigas. Nenhum endpoint de
  # escrita da Yampi é chamado aqui.
  def refresh_preview!(registration)
    if yampi_destination?(registration) && !registration.images.attached?
      existing = existing_product_for_sku(registration)
      result = Products::IdworksSkuImageResolverService.new(
        tenant: current_tenant,
        sku: registration.sku,
        parent_product: registration.parent_product,
        existing_product: existing
      ).call

      metadata = registration.metadata.merge(
        "source_image_provider" => "idworks",
        "source_image_resolved_at" => Time.current.iso8601,
        "source_image_errors" => result.errors,
        "source_image_urls" => result.found? ? result.image_urls : [],
        "source_image_sku" => result.source_sku,
        "source_image_fallback_to_parent" => result.fallback_to_parent == true
      )

      if result.found?
        metadata.merge!(
          "source_image_details" => result.images,
          "source_image_idworks_id" => result.idworks_id,
          "source_image_integration_id" => result.integration_id,
          "source_image_integration_name" => result.integration_name
        )
      else
        metadata = metadata.except(
          "source_image_details",
          "source_image_idworks_id",
          "source_image_integration_id",
          "source_image_integration_name"
        )
      end

      registration.update!(metadata: metadata)
    end

    if registration.product_id.blank?
      errors = registration_service.validation_messages(registration.reload)
      registration.update!(
        validation_errors: errors,
        status: errors.empty? ? "ready" : "draft"
      )
    end

    registration.reload
  end

  def yampi_destination?(registration)
    registration.publications.any? { |publication| publication.channel == "yampi" }
  end

  def existing_product_for_sku(registration)
    normalized = registration.sku.to_s.strip.downcase
    return nil if normalized.blank?

    current_tenant.products.where("LOWER(sku) = ?", normalized).first
  end

  def preview_payload(registration)
    image_urls = Array(registration.metadata["source_image_urls"])
    existing = existing_product_for_sku(registration)
    fallback = registration.metadata["source_image_fallback_to_parent"] == true

    {
      confirmacao_necessaria: true,
      mensagem: registration.validation_errors.empty? ?
        "Prévia atualizada. Nada foi escrito na Yampi. Revise produto, preço, imagem e destino; depois chame novamente com confirmar:true." :
        "Prévia atualizada, mas há bloqueios de validação. Nada foi escrito na Yampi.",
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
      produto_pricecom_existente: existing && {
        id: existing.id,
        sku: existing.sku,
        nome: existing.name
      },
      estrategia_pricecom: existing ? "reutilizar_produto_existente" : "criar_produto_local_na_publicacao",
      imagem_idworks: {
        encontrada: image_urls.any?,
        sku_origem: registration.metadata["source_image_sku"],
        fallback_produto_base: fallback,
        observacao: fallback ? "A variação não tinha imagem própria; será usada a imagem do produto-base." : nil,
        idworks_id: registration.metadata["source_image_idworks_id"],
        integracao: registration.metadata["source_image_integration_name"],
        urls: image_urls,
        detalhes: registration.metadata["source_image_details"],
        erros: registration.metadata["source_image_errors"]
      }.compact,
      validacao: registration.validation_errors,
      destinos: publication_payloads(registration),
      proximo_passo: registration.validation_errors.empty? ?
        "Se estiver correto, chame PublicarCadastroProdutoTool novamente com cadastro_id=#{registration.id} e confirmar:true." :
        "Não confirme a publicação até os bloqueios acima serem resolvidos."
    }
  end

  def result_payload(registration)
    fallback = registration.metadata["source_image_fallback_to_parent"] == true

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
        sku_origem: registration.metadata["source_image_sku"],
        fallback_produto_base: fallback,
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
