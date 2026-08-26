# frozen_string_literal: true

class VincularProdutoCanalTool < ApplicationTool
  description <<~DESC
    Vincula um anúncio/SKU que JÁ EXISTE na Yampi ou TikTok ao Product correto
    do Pricecom. Consulta o canal ao vivo e não recria produto. Com confirmar:false
    mostra o vínculo proposto; confirmar:true persiste. Se o external_id já estiver
    ligado a outro Product, exige forcar:true além da confirmação.
  DESC

  arguments do
    required(:busca).filled(:string).description("SKU, nome exato ou ID interno do Product no Pricecom")
    required(:canal).filled(:string).description("yampi ou tiktok")
    required(:confirmar).filled(:bool).description("false = prévia; true = efetivar vínculo")
    optional(:credencial_canal_id).filled(:integer).description("Conexão específica quando houver mais de uma loja do canal")
    optional(:external_id).filled(:string).description("ID externo do SKU quando houver duplicidade e você quiser escolher explicitamente")
    optional(:forcar).filled(:bool).description("Permite mover um external_id já vinculado a outro Product; padrão false")
  end

  def call(busca:, canal:, confirmar:, credencial_canal_id: nil, external_id: nil, forcar: false)
    return error if (error = require_admin!)

    tenant = current_tenant
    return "Usuário sem tenant associado." unless tenant

    channel = canal.to_s.strip.downcase
    return { erro: "Canal não suportado para vínculo", canais: %w[yampi tiktok] } unless %w[yampi tiktok].include?(channel)

    product = resolve_product(tenant, busca)
    return { erro: "Produto não encontrado no Pricecom", busca: busca } unless product

    inspection = Products::OmnichannelProductInspectorService.new(tenant: tenant, busca: product.sku).call
    selected = select_remote_candidate(inspection, channel, credencial_canal_id, external_id)
    return selected if selected.is_a?(Hash) && selected[:erro]

    credential_id = selected[:credencial_canal_id]
    credential = tenant.channel_credentials.find_by(id: credential_id, channel: channel)
    return { erro: "Credencial do canal não encontrada", credencial_canal_id: credential_id } unless credential

    existing_listing = ChannelProductListing.find_by(
      tenant: tenant,
      channel_credential: credential,
      external_id: selected[:sku_id].to_s
    )

    conflict = existing_listing && existing_listing.product_id != product.id
    if conflict && !forcar
      return {
        erro: "O anúncio externo já está vinculado a outro Product.",
        produto_solicitado: product_payload(product),
        produto_atual: product_payload(existing_listing.product),
        anuncio: selected,
        acao: "Revise e repita com forcar:true somente se o vínculo atual estiver realmente errado."
      }
    end

    preview = {
      confirmacao_necessaria: true,
      acao: existing_listing ? (conflict ? "mover_vinculo_existente" : "atualizar_vinculo_existente") : "criar_vinculo_local",
      nenhuma_criacao_remota: true,
      produto_pricecom: product_payload(product),
      anuncio_remoto: selected,
      vinculo_atual: listing_payload(existing_listing),
      forcar: !!forcar
    }.compact
    return preview unless confirmar

    listing = existing_listing || ChannelProductListing.new(
      tenant: tenant,
      channel: channel,
      channel_credential: credential,
      external_id: selected[:sku_id].to_s
    )

    listing.product = product
    apply_remote_snapshot!(listing, selected, channel)
    listing.save!

    log_activity!(
      action: "channel_product_listing.linked",
      target: listing,
      metadata: {
        source: "mcp",
        channel: channel,
        product_id: product.id,
        sku: product.sku,
        external_id: listing.external_id,
        external_product_id: listing.external_product_id,
        channel_credential_id: credential.id,
        forced_relink: conflict && !!forcar
      }
    )

    {
      vinculado: true,
      nenhuma_criacao_remota: true,
      produto_pricecom: product_payload(product),
      anuncio: selected,
      listing: listing_payload(listing.reload)
    }
  rescue ActiveRecord::RecordInvalid => e
    { erro: "Não foi possível salvar o vínculo", validacao: e.record.errors.full_messages }
  rescue => e
    { erro: "Falha ao vincular produto", error_class: e.class.name, detalhe: e.message.to_s.first(500) }
  end

  private

  def resolve_product(tenant, value)
    scope = tenant.products
    raw = value.to_s.strip
    scope.find_by("LOWER(sku) = ?", raw.downcase) ||
      (raw.match?(/\A\d+\z/) ? scope.find_by(id: raw.to_i) : nil) ||
      scope.find_by("LOWER(name) = ?", raw.downcase)
  end

  def select_remote_candidate(inspection, channel, credential_id, external_id)
    connections = Array(inspection.dig(channel.to_sym, :conexoes))
    connections.select! { |row| row[:credencial_canal_id].to_i == credential_id.to_i } if credential_id.present?

    if connections.empty?
      return { erro: "Nenhuma conexão #{channel} disponível para esta consulta." }
    end

    if credential_id.blank? && connections.count { |row| Array(row[:encontrados]).any? } > 1
      return {
        erro: "O SKU existe em mais de uma conexão #{channel}; informe credencial_canal_id.",
        conexoes: connections.map { |row| { credencial_canal_id: row[:credencial_canal_id], loja: row[:loja], quantidade: Array(row[:encontrados]).size } }
      }
    end

    candidates = connections.flat_map { |row| Array(row[:encontrados]) }
    return { erro: "SKU não encontrado ao vivo no canal #{channel}. Não há o que vincular." } if candidates.empty?

    if external_id.present?
      found = candidates.find { |candidate| candidate[:sku_id].to_s == external_id.to_s }
      return found if found

      return {
        erro: "external_id não corresponde a nenhum SKU encontrado.",
        external_id: external_id,
        encontrados: candidates.map { |c| { sku_id: c[:sku_id], product_id: c[:product_id], loja: c[:loja] } }
      }
    end

    connection = connections.find { |row| Array(row[:encontrados]).any? }
    if connection[:selecao_ambigua]
      return {
        erro: "Há mais de um candidato igualmente válido; informe external_id.",
        encontrados: connection[:encontrados]
      }
    end

    preferred = connection[:preferido]
    return preferred if preferred
    return candidates.first if candidates.one?

    {
      erro: "Há múltiplos anúncios e não foi possível escolher com segurança; informe external_id.",
      encontrados: candidates
    }
  end

  def apply_remote_snapshot!(listing, candidate, channel)
    listing.channel = channel
    listing.external_sku = candidate[:sku].to_s
    listing.external_product_id = candidate[:product_id].to_s.presence
    listing.price = candidate[:preco]
    listing.stock_qty = candidate[:estoque]
    listing.raw_payload = candidate
    listing.synced_at = Time.current

    if channel == "yampi"
      enabled = candidate[:blocked_sale] == false
      listing.remote_status = enabled ? "active" : "blocked_sale"
      listing.remote_status_reason = enabled ? nil : "blocked_sale"
      listing.selling_status = enabled ? "selling" : "inactive"
      listing.selling_enabled = enabled
      listing.replenishment_eligible = enabled
    else
      listing.remote_status = candidate[:status_remoto].presence || "unknown"
      listing.remote_status_reason = nil
      listing.selling_status = candidate[:status_venda].presence || "unknown"
      listing.selling_enabled = candidate[:venda_habilitada] == true
      listing.replenishment_eligible = candidate[:venda_habilitada] == true
    end
    listing.remote_status_metadata = { "source" => "mcp_live_link" }
    listing.remote_status_synced_at = Time.current
  end

  def product_payload(product)
    return nil unless product
    { id: product.id, sku: product.sku, nome: product.name }
  end

  def listing_payload(listing)
    return nil unless listing
    {
      listing_id: listing.id,
      product_id: listing.product_id,
      canal: listing.channel,
      credencial_canal_id: listing.channel_credential_id,
      external_id: listing.external_id,
      external_product_id: listing.external_product_id,
      external_sku: listing.external_sku,
      preco: listing.price,
      estoque: listing.stock_qty,
      status_venda: listing.selling_status,
      venda_habilitada: listing.selling_enabled
    }
  end
end
