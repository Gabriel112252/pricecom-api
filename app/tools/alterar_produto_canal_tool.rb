# frozen_string_literal: true

class AlterarProdutoCanalTool < ApplicationTool
  description <<~DESC
    Altera um anúncio/SKU existente na Yampi ou TikTok usando dados AO VIVO.
    Suporta preço, estoque e ativação/desativação. Também pode copiar o preço
    atual de idworks, yampi ou tiktok. Com confirmar:false retorna antes/depois
    sem escrever; confirmar:true executa e reconsulta o canal.
  DESC

  arguments do
    required(:busca).filled(:string).description("SKU, nome exato ou ID interno do Product")
    required(:canal).filled(:string).description("yampi ou tiktok")
    required(:confirmar).filled(:bool).description("false = prévia; true = executar")
    optional(:preco).filled(:float).description("Novo preço de venda")
    optional(:copiar_preco_de).filled(:string).description("Fonte: idworks, yampi ou tiktok")
    optional(:estoque).filled(:integer).description("Novo estoque absoluto")
    optional(:ativo).filled(:bool).description("Ativa/desativa venda no canal")
    optional(:credencial_canal_id).filled(:integer).description("Loja/conexão específica")
    optional(:external_id).filled(:string).description("SKU ID remoto explícito quando houver duplicidade")
  end

  def call(busca:, canal:, confirmar:, preco: nil, copiar_preco_de: nil, estoque: nil, ativo: nil,
           credencial_canal_id: nil, external_id: nil)
    return error if (error = require_admin!)

    tenant = current_tenant
    return "Usuário sem tenant associado." unless tenant

    channel = canal.to_s.strip.downcase
    return { erro: "Canal não suportado", canais: %w[yampi tiktok] } unless %w[yampi tiktok].include?(channel)

    inspection = Products::OmnichannelProductInspectorService.new(tenant: tenant, busca: busca).call
    sku = inspection[:sku]
    selected = select_remote_candidate(inspection, channel, credencial_canal_id, external_id)
    return selected if selected.is_a?(Hash) && selected[:erro]

    credential = tenant.channel_credentials.find_by(id: selected[:credencial_canal_id], channel: channel)
    return { erro: "Credencial do canal não encontrada" } unless credential

    target_price = resolve_target_price(inspection, preco, copiar_preco_de, channel, credential.id)
    return target_price if target_price.is_a?(Hash) && target_price[:erro]

    changes = {}
    changes[:preco] = { de: selected[:preco], para: target_price } unless target_price.nil?
    changes[:estoque] = { de: selected[:estoque], para: estoque.to_i } unless estoque.nil?
    changes[:ativo] = { de: selected[:venda_habilitada], para: !!ativo } unless ativo.nil?

    return { erro: "Informe ao menos uma alteração: preco, copiar_preco_de, estoque ou ativo." } if changes.empty?
    if estoque && estoque.to_i.negative?
      return { erro: "Estoque não pode ser negativo." }
    end

    preview = {
      confirmacao_necessaria: true,
      sku: sku,
      canal: channel,
      credencial_canal_id: credential.id,
      loja: credential.display_name,
      external_id: selected[:sku_id],
      external_product_id: selected[:product_id],
      atual: selected,
      alteracoes: changes,
      fonte_preco: copiar_preco_de.presence,
      observacao: "Nenhuma escrita foi feita. Chame novamente com confirmar:true para executar."
    }.compact
    return preview unless confirmar

    execute_changes!(channel, credential, selected, target_price, estoque, ativo)

    refreshed = Products::OmnichannelProductInspectorService.new(tenant: tenant, busca: sku).call
    refreshed_selected = select_remote_candidate(refreshed, channel, credential.id, selected[:sku_id].to_s)
    refresh_local_listing!(tenant, credential, refreshed_selected) unless refreshed_selected[:erro]

    log_target = resolve_product(tenant, sku) || credential
    log_activity!(
      action: "channel_product_listing.updated_remote",
      target: log_target,
      metadata: {
        source: "mcp",
        sku: sku,
        channel: channel,
        channel_credential_id: credential.id,
        external_id: selected[:sku_id],
        external_product_id: selected[:product_id],
        changes: changes
      }
    )

    {
      alterado: true,
      sku: sku,
      canal: channel,
      alteracoes_solicitadas: changes,
      antes: selected,
      depois: refreshed_selected,
      comparacao_precos_atualizada: refreshed[:comparacao_precos]
    }
  rescue Integrations::AuthenticationError, Integrations::RateLimitError, Integrations::ApiError => e
    { erro: "Canal recusou a alteração", error_class: e.class.name, detalhe: e.message.to_s.first(500) }
  rescue ArgumentError => e
    { erro: e.message }
  rescue => e
    { erro: "Falha ao alterar produto no canal", error_class: e.class.name, detalhe: e.message.to_s.first(500) }
  end

  private

  def execute_changes!(channel, credential, selected, price, stock, active)
    if channel == "yampi"
      client = Integrations::YampiCatalogWriteClient.new(credential.credentials)
      client.update_sku(selected[:sku_id], price_sale: price) unless price.nil?

      unless stock.nil?
        Integrations::YampiAdapter.new(credential.credentials).update_stock(
          external_id: selected[:sku_id],
          quantity: stock.to_i
        )
      end

      unless active.nil?
        client.update_product(selected[:product_id], active: !!active)
        client.update_sku(selected[:sku_id], blocked_sale: !active)
      end
    else
      adapter = Integrations::TiktokCatalogWriteClient.new(credential.credentials)
      unless price.nil?
        adapter.update_price(
          external_id: selected[:sku_id],
          product_id: selected[:product_id],
          amount: price,
          currency: selected[:moeda].presence || "BRL"
        )
      end
      unless stock.nil?
        adapter.update_stock(
          external_id: selected[:sku_id],
          quantity: stock.to_i,
          product_id: selected[:product_id]
        )
      end
      unless active.nil?
        active ? adapter.activate_product(product_id: selected[:product_id]) : adapter.deactivate_product(product_id: selected[:product_id])
      end
    end
  end

  def resolve_target_price(inspection, explicit, source, destination_channel, destination_credential_id)
    if explicit
      value = BigDecimal(explicit.to_s)
      return { erro: "Preço precisa ser maior que zero." } unless value.positive?
      return value.to_f
    end

    return nil if source.blank?
    source_channel = source.to_s.strip.downcase

    case source_channel
    when "idworks"
      value = inspection.dig(:idworks, :preco_venda)
      return { erro: "IDWorks não retornou PriceSell para este SKU." } if value.blank?
      value.to_f
    when "yampi", "tiktok"
      connections = Array(inspection.dig(source_channel.to_sym, :conexoes))
      candidates = connections.filter_map { |connection| connection[:preferido] }

      if source_channel == destination_channel
        candidates = candidates.reject { |candidate| candidate[:credencial_canal_id].to_i == destination_credential_id.to_i }
      end

      return { erro: "Não foi encontrado preço ao vivo em #{source_channel}." } if candidates.empty?
      if candidates.size > 1
        return {
          erro: "Há mais de uma fonte de preço #{source_channel}; informe preco explicitamente para evitar escolher a loja errada.",
          fontes: candidates.map { |c| { loja: c[:loja], credencial_canal_id: c[:credencial_canal_id], preco: c[:preco] } }
        }
      end

      value = candidates.first[:preco]
      return { erro: "#{source_channel} não retornou preço para o SKU." } if value.blank?
      value.to_f
    else
      { erro: "copiar_preco_de inválido", fontes: %w[idworks yampi tiktok] }
    end
  rescue ArgumentError
    { erro: "Preço inválido." }
  end

  def select_remote_candidate(inspection, channel, credential_id, external_id)
    connections = Array(inspection.dig(channel.to_sym, :conexoes))
    connections.select! { |row| row[:credencial_canal_id].to_i == credential_id.to_i } if credential_id.present?

    with_results = connections.select { |row| Array(row[:encontrados]).any? }
    return { erro: "SKU não encontrado ao vivo em #{channel}." } if with_results.empty?

    if credential_id.blank? && with_results.size > 1
      return {
        erro: "SKU encontrado em mais de uma conexão #{channel}; informe credencial_canal_id.",
        conexoes: with_results.map { |row| { credencial_canal_id: row[:credencial_canal_id], loja: row[:loja] } }
      }
    end

    connection = with_results.first
    candidates = Array(connection[:encontrados])
    if external_id.present?
      candidate = candidates.find { |item| item[:sku_id].to_s == external_id.to_s }
      return candidate if candidate
      return { erro: "external_id não encontrado nesta conexão", encontrados: candidates.map { |item| item[:sku_id] } }
    end

    return { erro: "Duplicidade ambígua; informe external_id.", encontrados: candidates } if connection[:selecao_ambigua]
    connection[:preferido] || (candidates.one? ? candidates.first : { erro: "Múltiplos candidatos; informe external_id.", encontrados: candidates })
  end

  def refresh_local_listing!(tenant, credential, candidate)
    listing = ChannelProductListing.find_by(
      tenant: tenant,
      channel_credential: credential,
      external_id: candidate[:sku_id].to_s
    )
    return unless listing

    listing.update!(
      price: candidate[:preco],
      stock_qty: candidate[:estoque],
      external_product_id: candidate[:product_id].to_s,
      external_sku: candidate[:sku].to_s,
      raw_payload: candidate,
      synced_at: Time.current,
      remote_status_synced_at: Time.current
    )
  end

  def resolve_product(tenant, value)
    raw = value.to_s.strip
    tenant.products.find_by("LOWER(sku) = ?", raw.downcase) ||
      (raw.match?(/\A\d+\z/) ? tenant.products.find_by(id: raw.to_i) : nil)
  end
end
