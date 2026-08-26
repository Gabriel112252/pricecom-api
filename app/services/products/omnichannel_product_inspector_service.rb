# frozen_string_literal: true

module Products
  # Visão 360 ao vivo de um SKU. O banco do Pricecom é mostrado como vínculo
  # local, mas IDWorks/Yampi/TikTok são consultados diretamente para evitar
  # tomar decisões de cadastro/preço em cima de snapshots antigos.
  class OmnichannelProductInspectorService
    MAX_IDWORKS_HUB_PAGES = 20

    def initialize(tenant:, busca:)
      @tenant = tenant
      @busca = busca.to_s.strip
    end

    def call
      product = resolve_product
      sku = product&.sku.to_s.presence || busca
      raise ArgumentError, "Informe um SKU, nome ou ID de produto." if sku.blank?

      idworks = inspect_idworks(sku, product)
      yampi = inspect_yampi(sku)
      tiktok = inspect_tiktok(sku)
      pricecom = inspect_pricecom(product, sku)

      result = {
        consulta: busca,
        sku: sku,
        produto_pricecom: pricecom,
        idworks: idworks,
        yampi: yampi,
        tiktok: tiktok
      }
      result[:comparacao_precos] = price_comparison(result)
      result[:divergencias] = divergences(result)
      result[:acoes_sugeridas] = suggested_actions(result)
      result
    end

    private

    attr_reader :tenant, :busca

    def resolve_product
      scope = tenant.products
      scope.find_by("LOWER(sku) = ?", busca.downcase) ||
        (busca.match?(/\A\d+\z/) ? scope.find_by(id: busca.to_i) : nil) ||
        scope.find_by("LOWER(name) = ?", busca.downcase)
    end

    def inspect_pricecom(product, sku)
      listings = if product
        product.channel_product_listings.includes(:channel_credential).order(:channel, :id)
      else
        tenant.channel_product_listings
          .includes(:channel_credential, :product)
          .where("LOWER(external_sku) = ?", sku.downcase)
          .order(:channel, :id)
      end

      {
        encontrado: product.present?,
        produto: product && {
          id: product.id,
          sku: product.sku,
          nome: product.name,
          custo: product.cost_price,
          estoque_erp_snapshot: product.qty_available,
          idworks_id: product.idworks_id,
          integration_id: product.integration_id,
          kit: product.is_kit
        },
        anuncios_vinculados: listings.map do |listing|
          {
            listing_id: listing.id,
            product_id: listing.product_id,
            product_sku: listing.product&.sku || product&.sku,
            canal: listing.channel,
            credencial_canal_id: listing.channel_credential_id,
            loja: listing.channel_credential&.display_name,
            external_id: listing.external_id,
            external_product_id: listing.external_product_id,
            external_sku: listing.external_sku,
            preco: decimal_value(listing.price),
            estoque: decimal_value(listing.stock_qty),
            status_remoto: listing.remote_status,
            status_venda: listing.selling_status,
            venda_habilitada: listing.selling_enabled,
            sincronizado_em: listing.synced_at
          }.compact
        end
      }
    end

    def inspect_idworks(sku, product)
      snapshot = IdworksSkuSnapshotService.new(
        tenant: tenant,
        sku: sku,
        preferred_integration: product&.integration
      ).call

      unless snapshot.found?
        return {
          encontrado: false,
          sku: sku,
          erros: snapshot.errors
        }
      end

      raw = snapshot.raw || {}
      integration = tenant.integrations.find_by(id: snapshot.integration_id)

      {
        encontrado: true,
        integration_id: snapshot.integration_id,
        integracao: snapshot.integration_name,
        idworks_id: snapshot.idworks_id,
        sku: sku,
        nome: snapshot.name,
        tipo_produto: snapshot.type_product,
        preco_venda: decimal_value(raw["PriceSell"]),
        preco_lista: decimal_value(raw["PriceList"]),
        custo_medio: decimal_value(snapshot.cost_average),
        custo_ultima_compra: decimal_value(raw["CostLastPurchase"]),
        estoque_disponivel: snapshot.quantity_available,
        estoque_reservado: decimal_value(raw["QtyReserved"]),
        estoque_manuseio: decimal_value(raw["QtyHandling"]),
        peso: decimal_value(snapshot.weight),
        altura: decimal_value(snapshot.height),
        largura: decimal_value(snapshot.width),
        comprimento: decimal_value(snapshot.length),
        ncm: snapshot.ncm,
        imagem_principal: raw["MainImageURL"],
        anuncios_hub: integration ? inspect_idworks_hub_ads(integration, sku, snapshot.idworks_id) : [],
        erros: snapshot.errors
      }.compact
    end

    # O IDWorks documenta GET /hub/product como a fonte dos anúncios/ofertas
    # enviados aos canais. GroupByHubSku=1 deixa a resposta mais adequada ao
    # match por SKU. Tentamos Search primeiro e fazemos fallback paginado se o
    # tenant/API não aceitar o filtro.
    def inspect_idworks_hub_ads(integration, sku, idworks_id)
      client = Integrations::Idworks::BaseClient.new(integration.credentials)
      client.authenticate!

      records = begin
        extract_rows(client.get("hub/product", {
          "Page" => 0,
          "GroupByHubSku" => 1,
          "Search" => sku
        }))
      rescue Integrations::ApiError
        []
      end

      matches = exact_hub_matches(records, sku, idworks_id)
      return matches.map { |row| compact_hub_ad(row, sku) } if matches.any?

      0.upto(MAX_IDWORKS_HUB_PAGES) do |page|
        page_rows = extract_rows(client.get("hub/product", "Page" => page, "GroupByHubSku" => 1))
        break if page_rows.empty?

        matches.concat(exact_hub_matches(page_rows, sku, idworks_id))
        break if matches.any?
      end

      matches.uniq { |row| first_present(row, "IDHubProduct", "IDHubSku", "id") || row.hash }
        .map { |row| compact_hub_ad(row, sku) }
    rescue => e
      [ { erro: e.message.to_s.first(300), error_class: e.class.name } ]
    end

    def inspect_yampi(sku)
      connections = tenant.channel_credentials.where(channel: "yampi").order(:id).map do |credential|
        begin
          client = Integrations::YampiCatalogWriteClient.new(credential.credentials)
          matches = client.all_skus.select { |row| row["sku"].to_s.strip.casecmp?(sku) }
          detailed = matches.map do |row|
            detail = client.fetch_sku(row["id"])
            product_id = detail["product_id"].presence || row["product_id"].presence
            product = product_id.present? ? client.fetch_product(product_id) : {}
            images = client.sku_images(detail["id"] || row["id"])
            yampi_candidate_payload(credential, detail.merge(row), product, images)
          end
          preferred, ambiguous = choose_yampi_candidate(detailed)

          {
            credencial_canal_id: credential.id,
            loja: credential.display_name,
            status_conexao: credential.status,
            encontrados: detailed,
            quantidade_encontrada: detailed.size,
            duplicado: detailed.size > 1,
            preferido: preferred,
            selecao_ambigua: ambiguous
          }
        rescue => e
          {
            credencial_canal_id: credential.id,
            loja: credential.display_name,
            status_conexao: credential.status,
            encontrados: [],
            erro: e.message.to_s.first(300),
            error_class: e.class.name
          }
        end
      end

      {
        encontrado: connections.any? { |row| Array(row[:encontrados]).any? },
        conexoes: connections
      }
    end

    def inspect_tiktok(sku)
      connections = tenant.channel_credentials.where(channel: "tiktok").order(:id).map do |credential|
        begin
          adapter = Integrations::TiktokAdapter.new(credential.credentials)
          raw_matches = adapter.fetch_products.select do |raw|
            raw["seller_sku"].to_s.strip.casecmp?(sku)
          end
          normalized = raw_matches.map do |raw|
            data = adapter.normalize_product(raw)
            {
              credencial_canal_id: credential.id,
              loja: credential.display_name,
              sku_id: data[:external_id],
              product_id: data[:external_product_id],
              sku: data[:external_sku],
              nome: data[:name],
              preco: decimal_value(data[:price]),
              moeda: raw.dig("price", "currency"),
              estoque: decimal_value(data[:stock_qty]),
              status_remoto: data[:remote_status],
              status_venda: data[:selling_status],
              venda_habilitada: data[:selling_enabled],
              inventario: raw["inventory"]
            }.compact
          end

          {
            credencial_canal_id: credential.id,
            loja: credential.display_name,
            status_conexao: credential.status,
            encontrados: normalized,
            quantidade_encontrada: normalized.size,
            duplicado: normalized.size > 1,
            preferido: normalized.one? ? normalized.first : choose_tiktok_candidate(normalized)
          }
        rescue => e
          {
            credencial_canal_id: credential.id,
            loja: credential.display_name,
            status_conexao: credential.status,
            encontrados: [],
            erro: e.message.to_s.first(300),
            error_class: e.class.name
          }
        end
      end

      {
        encontrado: connections.any? { |row| Array(row[:encontrados]).any? },
        conexoes: connections
      }
    end

    def yampi_candidate_payload(credential, sku, product, images)
      {
        credencial_canal_id: credential.id,
        loja: credential.display_name,
        sku_id: sku["id"]&.to_s,
        product_id: (sku["product_id"] || product["id"])&.to_s,
        sku: sku["sku"],
        nome: sku["title"].presence || product["name"],
        produto_simples: product["simple"],
        tem_variacoes: product["has_variations"],
        preco: decimal_value(sku["price_sale"]),
        preco_desconto: decimal_value(sku["price_discount"]),
        estoque: decimal_value(sku["total_in_stock"] || sku["availability"]),
        blocked_sale: sku["blocked_sale"],
        venda_habilitada: sku["blocked_sale"] == false,
        purchase_url: sku["purchase_url"],
        url_produto: product["url"],
        imagens: Array(images).map { |img| img["large"]&.[]("url") || img["medium"]&.[]("url") || img["name"] }.compact,
        criado_em: sku.dig("created_at", "date"),
        atualizado_em: sku.dig("updated_at", "date")
      }.compact
    end

    def choose_yampi_candidate(candidates)
      return [ nil, false ] if candidates.empty?

      scores = candidates.map { |candidate| [ candidate, yampi_candidate_score(candidate) ] }
      best_score = scores.map(&:last).max
      best = scores.select { |(_, score)| score == best_score }.map(&:first)
      [ best.first, best.size > 1 ]
    end

    def yampi_candidate_score(candidate)
      score = 0
      score += 100 if candidate[:blocked_sale] == false
      score += 50 if candidate[:estoque].to_d.positive?
      score += 20 if candidate[:purchase_url].present?
      score += 10 if candidate[:produto_simples] == true
      score
    end

    def choose_tiktok_candidate(candidates)
      candidates.max_by do |candidate|
        (candidate[:venda_habilitada] ? 100 : 0) +
          (candidate[:estoque].to_d.positive? ? 50 : 0)
      end
    end

    def price_comparison(result)
      rows = []
      if result.dig(:idworks, :encontrado)
        rows << { fonte: "idworks", preco: result.dig(:idworks, :preco_venda), tipo: "PriceSell" }
      end

      Array(result.dig(:yampi, :conexoes)).each do |connection|
        candidate = connection[:preferido]
        next unless candidate
        rows << {
          fonte: "yampi",
          credencial_canal_id: connection[:credencial_canal_id],
          loja: connection[:loja],
          preco: candidate[:preco],
          preco_desconto: candidate[:preco_desconto],
          external_id: candidate[:sku_id]
        }.compact
      end

      Array(result.dig(:tiktok, :conexoes)).each do |connection|
        candidate = connection[:preferido]
        next unless candidate
        rows << {
          fonte: "tiktok",
          credencial_canal_id: connection[:credencial_canal_id],
          loja: connection[:loja],
          preco: candidate[:preco],
          moeda: candidate[:moeda],
          external_id: candidate[:sku_id]
        }.compact
      end
      rows
    end

    def divergences(result)
      issues = []

      Array(result.dig(:yampi, :conexoes)).each do |connection|
        if connection[:duplicado]
          issues << {
            tipo: "sku_duplicado_yampi",
            canal: "yampi",
            credencial_canal_id: connection[:credencial_canal_id],
            quantidade: connection[:quantidade_encontrada],
            ids: Array(connection[:encontrados]).map { |item| item[:sku_id] }
          }
        end
      end

      Array(result.dig(:tiktok, :conexoes)).each do |connection|
        if connection[:duplicado]
          issues << {
            tipo: "sku_duplicado_tiktok",
            canal: "tiktok",
            credencial_canal_id: connection[:credencial_canal_id],
            quantidade: connection[:quantidade_encontrada],
            ids: Array(connection[:encontrados]).map { |item| item[:sku_id] }
          }
        end
      end

      if result.dig(:produto_pricecom, :encontrado)
        local = Array(result.dig(:produto_pricecom, :anuncios_vinculados))
        %w[yampi tiktok].each do |channel|
          remote = result[channel.to_sym]
          next unless remote && remote[:encontrado]

          remote_ids = Array(remote[:conexoes]).flat_map { |c| Array(c[:encontrados]).map { |x| x[:sku_id].to_s } }
          local_ids = local.select { |l| l[:canal] == channel }.map { |l| l[:external_id].to_s }
          missing_links = remote_ids - local_ids
          issues << { tipo: "anuncio_remoto_sem_vinculo_pricecom", canal: channel, external_ids: missing_links } if missing_links.any?
        end
      end

      prices = Array(result[:comparacao_precos]).filter_map { |row| row[:preco]&.to_d }.uniq
      if prices.size > 1
        issues << {
          tipo: "precos_divergentes",
          valores: result[:comparacao_precos]
        }
      end

      issues
    end

    def suggested_actions(result)
      result[:divergencias].filter_map do |issue|
        case issue[:tipo]
        when "anuncio_remoto_sem_vinculo_pricecom"
          "Vincular o anúncio #{issue[:canal]} existente ao Product do Pricecom; não recriar."
        when "sku_duplicado_yampi", "sku_duplicado_tiktok"
          "Revisar duplicidade em #{issue[:canal]} e manter/vincular o anúncio vendável correto antes de qualquer nova criação."
        when "precos_divergentes"
          "Comparar a estratégia de preço e, se desejado, usar AlterarProdutoCanalTool para igualar o canal escolhido."
        end
      end.uniq
    end

    def exact_hub_matches(rows, sku, idworks_id)
      Array(rows).select { |row| hub_record_matches?(row, sku, idworks_id) }
    end

    def hub_record_matches?(value, sku, idworks_id)
      case value
      when Hash
        direct_values = [
          value["IDSkuCompany"], value["Sku"], value["SKU"], value["sku"],
          value["SellerSku"], value["seller_sku"], value["IDSku"]
        ].compact.map { |item| item.to_s.strip }
        return true if direct_values.any? { |item| item.casecmp?(sku) }
        return true if idworks_id.present? && direct_values.include?(idworks_id.to_s)

        value.values.any? { |nested| nested.is_a?(Hash) || nested.is_a?(Array) ? hub_record_matches?(nested, sku, idworks_id) : false }
      when Array
        value.any? { |nested| hub_record_matches?(nested, sku, idworks_id) }
      else
        false
      end
    end

    def compact_hub_ad(row, sku)
      hub_skus = collect_hashes(row).select do |item|
        code = first_present(item, "IDSkuCompany", "Sku", "SKU", "sku", "SellerSku", "seller_sku")
        code.to_s.strip.casecmp?(sku)
      end

      {
        id_hub_product: first_present(row, "IDHubProduct", "idHubProduct", "id"),
        codigo_anuncio: first_present(row, "HubProductCode", "Code", "code", "ExternalId", "external_id"),
        titulo: first_present(row, "Title", "title", "Name", "name", "HubProductName"),
        canal: first_present(row, "SalesChannel", "Channel", "Integration", "CompanyIntegrationName", "TypeIntegration"),
        id_integracao_canal: first_present(row, "IDCompanyIntegration", "idCompanyIntegration"),
        status: first_present(row, "Status", "status", "HubProductStatus", "TypeStatusHubProduct"),
        preco: decimal_value(first_present(row, "Price", "PriceSell", "price", "SalePrice")),
        hub_skus: hub_skus.map do |item|
          {
            id_hub_sku: first_present(item, "IDHubSku", "idHubSku", "id"),
            id_sku: first_present(item, "IDSku", "idSku"),
            sku: first_present(item, "IDSkuCompany", "Sku", "SKU", "sku", "SellerSku", "seller_sku"),
            preco: decimal_value(first_present(item, "Price", "PriceSell", "price", "SalePrice")),
            estoque: decimal_value(first_present(item, "Stock", "QtyAvailable", "Quantity", "quantity")),
            codigo_externo: first_present(item, "ExternalId", "external_id", "HubSkuCode", "Code")
          }.compact
        end
      }.compact
    end

    def collect_hashes(value, rows = [])
      case value
      when Hash
        rows << value
        value.values.each { |nested| collect_hashes(nested, rows) if nested.is_a?(Hash) || nested.is_a?(Array) }
      when Array
        value.each { |nested| collect_hashes(nested, rows) if nested.is_a?(Hash) || nested.is_a?(Array) }
      end
      rows
    end

    def extract_rows(body)
      return body if body.is_a?(Array)
      return [] unless body.is_a?(Hash)

      %w[Data data Items items Records records Results results List list Rows rows HubProduct hubProduct].each do |key|
        value = body[key]
        return value if value.is_a?(Array)
        return extract_rows(value) if value.is_a?(Hash)
      end

      nested_array = body.values.find { |value| value.is_a?(Array) }
      return nested_array if nested_array

      nested_hash = body.values.find { |value| value.is_a?(Hash) }
      nested_hash ? extract_rows(nested_hash) : []
    end

    def first_present(hash, *keys)
      return nil unless hash.is_a?(Hash)

      keys.each do |key|
        value = hash[key]
        return value unless value.nil? || value == ""
      end
      nil
    end

    def decimal_value(value)
      return nil if value.nil? || value == ""
      BigDecimal(value.to_s).to_f
    rescue ArgumentError, TypeError
      value
    end
  end
end
