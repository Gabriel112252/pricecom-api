# frozen_string_literal: true

class PublicarCadastroProdutoTool < ApplicationTool
  description <<~DESC
    Publica um cadastro já validado na Yampi. `modo_yampi=variacao` adiciona
    um SKU ao produto-base. `modo_yampi=produto_simples` cria um NOVO produto
    normal/sem variações na Yampi, mantendo o SKU informado (ex.: 2142_2).
    Com confirmar:false apenas atualiza a prévia e não escreve na Yampi.
    Com confirmar:true efetiva exatamente o modo escolhido e devolve purchase_url.
  DESC

  arguments do
    required(:cadastro_id).filled(:integer).description("ID do ProductRegistration")
    required(:confirmar).filled(:bool).description("Use false para prévia atualizada; true para efetivar a publicação")
    optional(:modo_yampi).filled(:string).description("variacao (padrão) ou produto_simples para criar produto normal/avulso na Yampi")
  end

  def call(cadastro_id:, confirmar:, modo_yampi: nil)
    admin_error = require_admin!
    return admin_error if admin_error

    tenant = current_tenant
    return "Usuário sem tenant associado." unless tenant

    mode = normalize_mode(modo_yampi)
    return mode if mode.is_a?(Hash)

    registration = ProductRegistration
      .where(tenant: tenant)
      .includes(:parent_product, :product, publications: :channel_credential)
      .find_by(id: cadastro_id)
    return "Cadastro #{cadastro_id} não encontrado neste tenant." unless registration

    owner_error = ensure_same_creator(registration)
    return owner_error if owner_error

    mode_conflict = existing_remote_mode_conflict(registration, mode)
    return mode_conflict if mode_conflict

    unless confirmar
      registration = refresh_preview!(registration)
      return preview_payload(registration, mode)
    end

    registration = if mode == "produto_simples"
      Products::YampiSimpleProductRegistrationService.new(
        tenant: current_tenant,
        user: current_user
      ).publish!(registration)
    else
      registration_service.publish!(registration)
    end

    log_activity!(
      action: "product_registration.published",
      target: registration,
      metadata: {
        source: "mcp",
        sku: registration.sku,
        product_id: registration.product_id,
        modo_yampi: mode,
        reused_existing_product: registration.metadata["reused_existing_product"],
        source_image_sku: registration.metadata["source_image_sku"],
        source_image_fallback_to_parent: registration.metadata["source_image_fallback_to_parent"],
        channel_credential_ids: registration.publications.pluck(:channel_credential_id).compact
      }
    )

    result_payload(registration.reload, mode)
  rescue Products::ProductRegistrationService::ValidationError => e
    { erro: "Cadastro não pode ser publicado", validacao: e.errors }
  rescue ActiveRecord::RecordInvalid => e
    { erro: "Falha ao publicar cadastro", validacao: e.record.errors.full_messages }
  end

  private

  def normalize_mode(value)
    normalized = value.to_s.strip.downcase
    normalized = "variacao" if normalized.blank?

    return "variacao" if %w[variacao variação variant].include?(normalized)
    return "produto_simples" if %w[produto_simples produto-normal produto_normal normal simples avulso].include?(normalized)

    {
      erro: "modo_yampi inválido",
      valores_aceitos: [ "variacao", "produto_simples" ],
      dica: "Use produto_simples quando quiser criar um produto normal separado na Yampi, sem variations_values_ids."
    }
  end

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

  def existing_remote_mode_conflict(registration, mode)
    publication = registration.publications.find do |item|
      item.channel == "yampi" && item.external_variant_id.present?
    end
    return nil unless publication

    existing_mode = publication.metadata["publication_mode"].presence || "variacao"
    return nil if existing_mode == mode

    {
      erro: "O cadastro já possui publicação Yampi em outro modo.",
      modo_existente: existing_mode,
      modo_solicitado: mode,
      acao: "Use DesfazerCadastroProdutoTool primeiro; depois publique novamente no modo desejado."
    }
  end

  # Prévia é read-only para Yampi. Atualiza apenas metadata/status do rascunho
  # no Pricecom para registrar imagem e validações atuais.
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

  def preview_payload(registration, mode)
    image_urls = Array(registration.metadata["source_image_urls"])
    existing = existing_product_for_sku(registration)
    fallback = registration.metadata["source_image_fallback_to_parent"] == true
    simple_mode = mode == "produto_simples"

    {
      confirmacao_necessaria: true,
      mensagem: registration.validation_errors.empty? ?
        (simple_mode ?
          "Prévia atualizada. Nada foi escrito na Yampi. Ao confirmar será criado um NOVO produto simples/normal, sem variations_values_ids." :
          "Prévia atualizada. Nada foi escrito na Yampi. Ao confirmar o SKU será publicado como variação do produto-base.") :
        "Prévia atualizada, mas há bloqueios de validação. Nada foi escrito na Yampi.",
      cadastro_id: registration.id,
      status: registration.status,
      modo_yampi: mode,
      efeito_na_yampi: simple_mode ? "criar_novo_produto_simples" : "adicionar_variacao_ao_produto_base",
      sku: registration.sku,
      nome: registration.name,
      preco_centavos: registration.price_cents,
      produto_base_usado_como_referencia: {
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
      seguranca_produto_simples: simple_mode ? {
        active: true,
        blocked_sale: true,
        estoque_inicial: 0,
        observacao: "O produto é criado normal e ativo no catálogo, mas o SKU nasce bloqueado para venda e sem estoque até revisão/configuração. O purchase_url ainda é retornado."
      } : nil,
      validacao: registration.validation_errors,
      destinos: publication_payloads(registration),
      proximo_passo: registration.validation_errors.empty? ?
        "Se estiver correto, chame PublicarCadastroProdutoTool novamente com cadastro_id=#{registration.id}, modo_yampi=#{mode} e confirmar:true." :
        "Não confirme a publicação até os bloqueios acima serem resolvidos."
    }.compact
  end

  def result_payload(registration, requested_mode)
    fallback = registration.metadata["source_image_fallback_to_parent"] == true

    {
      cadastro_id: registration.id,
      status: registration.status,
      modo_yampi_solicitado: requested_mode,
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
        "O link de compra da Yampi está em destinos[].url_compra. Se precisar reverter o que este fluxo criou, use DesfazerCadastroProdutoTool com este cadastro_id." :
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
        modo_publicacao: publication.metadata["publication_mode"],
        external_product_id: publication.external_product_id,
        external_variant_id: publication.external_variant_id,
        url_compra: publication.metadata["purchase_url"],
        produto_remoto_criado_por_este_fluxo: publication.metadata["remote_product_created_by_registration"],
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
