# frozen_string_literal: true

class ReplicarProdutoCanalTool < ApplicationTool
  description <<~DESC
    Cria um produto faltante usando outro SKU como EXEMPLO de estrutura, sem
    transformar o SKU destino em variação. Hoje a escrita automática é Yampi.
    Antes de criar consulta IDWorks + canal ao vivo, impede duplicidade e mostra
    opções de preço. O SKU destino precisa existir no IDWorks. confirmar:false
    é só prévia; confirmar:true cria rascunho interno e publica produto simples.
  DESC

  arguments do
    required(:sku_exemplo).filled(:string).description("SKU já existente que serve de exemplo de estrutura")
    required(:sku_destino).filled(:string).description("SKU exato que será criado/vinculado")
    required(:canal).filled(:string).description("Hoje: yampi")
    required(:confirmar).filled(:bool).description("false = prévia; true = criar")
    optional(:preco).filled(:float).description("Preço de venda explícito")
    optional(:copiar_preco_de).filled(:string).description("idworks, tiktok_destino ou yampi_exemplo")
    optional(:nome).filled(:string).description("Nome do novo produto; padrão usa nome do IDWorks")
    optional(:credencial_canal_id).filled(:integer).description("Conexão Yampi específica")
  end

  def call(sku_exemplo:, sku_destino:, canal:, confirmar:, preco: nil, copiar_preco_de: nil,
           nome: nil, credencial_canal_id: nil)
    return error if (error = require_admin!)

    tenant = current_tenant
    return "Usuário sem tenant associado." unless tenant

    channel = canal.to_s.strip.downcase
    return { erro: "Replicação automática ainda suportada somente para Yampi." } unless channel == "yampi"

    example = Products::OmnichannelProductInspectorService.new(tenant: tenant, busca: sku_exemplo).call
    target = Products::OmnichannelProductInspectorService.new(tenant: tenant, busca: sku_destino).call

    unless target.dig(:idworks, :encontrado)
      return {
        erro: "SKU destino não existe no IDWorks; criação bloqueada.",
        sku_destino: sku_destino,
        idworks: target[:idworks]
      }
    end

    remote_target = yampi_candidates(target, credencial_canal_id)
    if remote_target.any?
      return {
        ja_existe_no_canal: true,
        criar: false,
        sku_destino: sku_destino,
        encontrados: remote_target,
        acao_recomendada: "Use VincularProdutoCanalTool para ligar o anúncio existente ao Pricecom; não crie duplicado."
      }
    end

    example_candidates = yampi_candidates(example, credencial_canal_id)
    return { erro: "SKU exemplo não foi encontrado ao vivo na Yampi." } if example_candidates.empty?

    credential = resolve_credential(tenant, credencial_canal_id, example_candidates)
    return credential if credential.is_a?(Hash) && credential[:erro]

    base_product = infer_target_base_product(tenant, sku_destino) || resolve_product(tenant, sku_exemplo)
    return { erro: "Não foi possível resolver um produto-base local seguro para o cadastro." } unless base_product

    selected_price = resolve_price(preco, copiar_preco_de, target, example, example_candidates)
    price_options = price_options(target, example_candidates)

    target_name = nome.to_s.strip.presence || target.dig(:idworks, :nome).presence ||
      target.dig(:produto_pricecom, :produto, :nome).presence || sku_destino.to_s

    preview = {
      confirmacao_necessaria: true,
      canal: "yampi",
      credencial_canal_id: credential.id,
      loja: credential.display_name,
      sku_exemplo: sku_exemplo,
      exemplo_yampi: example_candidates.first,
      sku_destino: sku_destino,
      produto_base_local_para_dados: { id: base_product.id, sku: base_product.sku, nome: base_product.name },
      destino_idworks: target[:idworks],
      nome: target_name,
      preco_escolhido: selected_price.is_a?(Numeric) ? selected_price : nil,
      opcoes_preco: price_options,
      modo_yampi: "produto_simples",
      efeito: "criar_novo_produto_simples_com_um_sku",
      observacao: "O exemplo serve para validar o padrão; dados físicos/custo vêm do SKU destino no IDWorks e imagem usa o SKU destino ou o produto-base da mesma família."
    }.compact

    if selected_price.is_a?(Hash) && selected_price[:erro]
      preview[:bloqueio] = selected_price
      return preview
    end

    unless confirmar
      preview[:proximo_passo] = "Revise e repita com confirmar:true."
      return preview
    end

    price_cents = (BigDecimal(selected_price.to_s) * 100).round.to_i
    registration = Products::ProductRegistrationService.new(
      tenant: tenant,
      user: current_user
    ).create_draft!(
      parent_product_id: base_product.id,
      sku: sku_destino,
      name: target_name,
      price_cents: price_cents,
      channel_credential_ids: [ credential.id ]
    )

    registration = Products::YampiSimpleProductRegistrationService.new(
      tenant: tenant,
      user: current_user
    ).publish!(registration)

    publication = registration.publications.find { |item| item.channel == "yampi" }

    log_activity!(
      action: "product_registration.replicated",
      target: registration,
      metadata: {
        source: "mcp",
        sku_example: sku_exemplo,
        sku: sku_destino,
        channel: "yampi",
        channel_credential_id: credential.id,
        publication_mode: "produto_simples",
        external_product_id: publication&.external_product_id,
        external_variant_id: publication&.external_variant_id
      }
    )

    {
      criado: publication&.status == "published",
      cadastro_id: registration.id,
      status: registration.status,
      sku: registration.sku,
      nome: registration.name,
      preco: selected_price,
      external_product_id: publication&.external_product_id,
      external_variant_id: publication&.external_variant_id,
      url_compra: publication&.metadata&.[]("purchase_url"),
      erro_codigo: publication&.error_code,
      erro: publication&.error_message
    }.compact
  rescue Products::ProductRegistrationService::ValidationError => e
    { erro: "Replicação bloqueada", validacao: e.errors }
  rescue => e
    { erro: "Falha ao replicar produto", error_class: e.class.name, detalhe: e.message.to_s.first(500) }
  end

  private

  def yampi_candidates(inspection, credential_id)
    connections = Array(inspection.dig(:yampi, :conexoes))
    connections.select! { |row| row[:credencial_canal_id].to_i == credential_id.to_i } if credential_id.present?
    connections.flat_map { |row| Array(row[:encontrados]) }
  end

  def resolve_credential(tenant, credential_id, example_candidates)
    if credential_id.present?
      credential = tenant.channel_credentials.find_by(id: credential_id, channel: "yampi")
      return credential || { erro: "Credencial Yampi não encontrada." }
    end

    ids = example_candidates.map { |candidate| candidate[:credencial_canal_id] }.compact.uniq
    return { erro: "Exemplo existe em várias lojas Yampi; informe credencial_canal_id.", credenciais: ids } if ids.size > 1

    credential = tenant.channel_credentials.find_by(id: ids.first, channel: "yampi")
    credential || { erro: "Não foi possível resolver a credencial Yampi do exemplo." }
  end

  def infer_target_base_product(tenant, sku)
    code = sku.to_s.strip
    base_code = code.sub(/_\d+\z/, "")
    return nil if base_code == code
    tenant.products.find_by("LOWER(sku) = ?", base_code.downcase)
  end

  def resolve_product(tenant, sku)
    tenant.products.find_by("LOWER(sku) = ?", sku.to_s.strip.downcase)
  end

  def price_options(target, example_candidates)
    {
      idworks: target.dig(:idworks, :preco_venda),
      tiktok_destino: Array(target.dig(:tiktok, :conexoes)).filter_map { |c| c[:preferido]&.[](:preco) }.uniq,
      yampi_exemplo: example_candidates.map { |candidate| candidate[:preco] }.compact.uniq
    }
  end

  def resolve_price(explicit, source, target, example, example_candidates)
    if explicit
      value = BigDecimal(explicit.to_s)
      return { erro: "Preço precisa ser maior que zero." } unless value.positive?
      return value.to_f
    end

    return { erro: "Informe preco ou copiar_preco_de antes de confirmar.", fontes: %w[idworks tiktok_destino yampi_exemplo] } if source.blank?

    case source.to_s.strip.downcase
    when "idworks"
      value = target.dig(:idworks, :preco_venda)
    when "tiktok_destino"
      values = Array(target.dig(:tiktok, :conexoes)).filter_map { |connection| connection[:preferido]&.[](:preco) }.compact.uniq
      return { erro: "Há mais de um preço TikTok para o destino; informe preco explicitamente.", valores: values } if values.size > 1
      value = values.first
    when "yampi_exemplo"
      values = example_candidates.map { |candidate| candidate[:preco] }.compact.uniq
      return { erro: "Há mais de um preço Yampi no exemplo; informe preco explicitamente.", valores: values } if values.size > 1
      value = values.first
    else
      return { erro: "copiar_preco_de inválido", fontes: %w[idworks tiktok_destino yampi_exemplo] }
    end

    return { erro: "A fonte escolhida não retornou preço." } if value.blank?
    value.to_f
  end
end
