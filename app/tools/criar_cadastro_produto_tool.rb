# frozen_string_literal: true

class CriarCadastroProdutoTool < ApplicationTool
  description <<~DESC
    Cria um rascunho de cadastro de produto/variação no Pricecom usando um
    produto-base e conexões de loja específicas. Permite selecionar duas ou
    mais lojas do mesmo canal, por exemplo TikTok Hidrabene e TikTok Anasol.
    AÇÃO DE ESCRITA — exige confirmar: true.
  DESC

  arguments do
    required(:produto_base_id).filled(:integer).description("ID do produto-base no Pricecom")
    required(:sku).filled(:string).description("SKU da nova variação")
    required(:nome).filled(:string).description("Nome da nova variação")
    required(:preco_centavos).filled(:integer).description("Preço de venda em centavos")
    required(:credenciais_canal_ids).array(:integer).description("IDs das conexões/lojas de destino")
    required(:confirmar).filled(:bool).description("Precisa ser true para criar o rascunho")
  end

  def call(produto_base_id:, sku:, nome:, preco_centavos:, credenciais_canal_ids:, confirmar:)
    admin_error = require_admin!
    return admin_error if admin_error

    tenant = current_tenant
    return "Usuário sem tenant associado." unless tenant

    parent = tenant.products.find_by(id: produto_base_id)
    return "Produto-base #{produto_base_id} não encontrado neste tenant." unless parent

    destinations = resolve_destinations(tenant, credenciais_canal_ids)
    return destinations if destinations.is_a?(String)

    unless confirmar
      return {
        confirmacao_necessaria: true,
        mensagem: "Revise os dados e chame novamente com confirmar: true para criar o rascunho.",
        produto_base: product_payload(parent),
        novo_produto: { sku: sku.to_s.strip, nome: nome.to_s.strip, preco_centavos: preco_centavos },
        destinos: destinations.map { |credential| destination_payload(credential) }
      }
    end

    registration = Products::ProductRegistrationService.new(
      tenant: tenant,
      user: current_user
    ).create_draft!(
      parent_product_id: parent.id,
      sku: sku,
      name: nome,
      price_cents: preco_centavos,
      channel_credential_ids: destinations.map(&:id)
    )

    log_activity!(
      action: "product_registration.created",
      target: registration,
      metadata: {
        source: "mcp",
        sku: registration.sku,
        parent_product_id: parent.id,
        channel_credential_ids: destinations.map(&:id)
      }
    )

    registration_payload(registration.reload)
  rescue Products::ProductRegistrationService::ValidationError => e
    { erro: "Cadastro inválido", validacao: e.errors }
  rescue ActiveRecord::RecordInvalid => e
    { erro: "Não foi possível criar o rascunho", validacao: e.record.errors.full_messages }
  end

  private

  def resolve_destinations(tenant, ids)
    normalized_ids = Array(ids).map(&:to_i).select(&:positive?).uniq
    return "Informe ao menos uma credencial_canal_id de destino." if normalized_ids.empty?

    credentials = tenant.channel_credentials.where(id: normalized_ids).order(:id).to_a
    missing = normalized_ids - credentials.map(&:id)
    return "Conexão(ões) não encontrada(s) neste tenant: #{missing.join(', ')}." if missing.any?

    unsupported = credentials.reject { |credential| ProductRegistrationPublication::CHANNELS.include?(credential.channel) }
    if unsupported.any?
      return "Canal(is) ainda não suportado(s) no cadastro guiado: #{unsupported.map(&:channel).uniq.join(', ')}."
    end

    credentials
  end

  def registration_payload(registration)
    {
      cadastro_id: registration.id,
      status: registration.status,
      sku: registration.sku,
      nome: registration.name,
      preco_centavos: registration.price_cents,
      produto_base: product_payload(registration.parent_product),
      validacao: registration.validation_errors,
      destinos: registration.publications.includes(:channel_credential).map do |publication|
        {
          publicacao_id: publication.id,
          canal: publication.channel,
          credencial_canal_id: publication.channel_credential_id,
          loja: publication.channel_credential&.display_name,
          status: publication.status
        }
      end,
      proximo_passo: registration.status == "ready" ?
        "O rascunho está válido. Use publicar_cadastro_produto com este cadastro_id." :
        "Corrija os itens de validação antes de publicar."
    }
  end

  def product_payload(product)
    { id: product.id, sku: product.sku, nome: product.name }
  end

  def destination_payload(credential)
    {
      credencial_canal_id: credential.id,
      canal: credential.channel,
      loja: credential.display_name,
      status: credential.status
    }
  end
end
