# frozen_string_literal: true

module Products
  # Resolve a imagem da VARIAÇÃO/SKU diretamente no IDWorks, sem depender
  # de Product#idworks_id estar sincronizado no Pricecom.
  #
  # A API pública do IDWorks documenta `IDSkuCompany` (LIKE) no GET /sku.
  # Não existe `IDSkuCompanyStrict`; portanto filtramos com IDSkuCompany e
  # confirmamos igualdade exata no payload antes de consultar a galeria.
  #
  # Para não confundir imagem herdada do produto-pai com arte própria da
  # variação, comparamos as URLs da galeria do SKU alvo com a galeria do
  # SKU-base e priorizamos somente URLs exclusivas do alvo.
  class IdworksSkuImageResolverService
    Result = Struct.new(
      :found,
      :sku,
      :idworks_id,
      :integration_id,
      :integration_name,
      :image_urls,
      :images,
      :errors,
      keyword_init: true
    ) do
      def found? = found == true
    end

    MAX_FALLBACK_PAGES = 20

    def initialize(tenant:, sku:, parent_product: nil, existing_product: nil)
      @tenant = tenant
      @sku = sku.to_s.strip
      @parent_product = parent_product
      @existing_product = existing_product
    end

    def call
      errors = []

      candidate_integrations.each do |integration|
        begin
          result = resolve_from(integration)
          return result if result
        rescue Integrations::AuthenticationError,
               Integrations::RateLimitError,
               Integrations::ApiError => e
          errors << safe_error(integration, e)
        rescue => e
          errors << safe_error(integration, e)
        end
      end

      Result.new(
        found: false,
        sku: sku,
        image_urls: [],
        images: [],
        errors: errors
      )
    end

    private

    attr_reader :tenant, :sku, :parent_product, :existing_product

    def candidate_integrations
      preferred = [ existing_product&.integration, parent_product&.integration ]
        .compact
        .select { |integration| integration.provider == "idworks" && integration.tenant_id == tenant.id }

      others = tenant.integrations.where(provider: "idworks").order(:id).to_a

      # O status `error` do sync periódico não impede uma leitura pontual.
      # Se as credenciais existem, tentamos a API diretamente.
      (preferred + others)
        .select(&:credentials_configured?)
        .uniq(&:id)
    end

    def resolve_from(integration)
      client = Integrations::Idworks::BaseClient.new(integration.credentials)
      client.authenticate!

      raw = find_exact_sku(client, sku)
      return nil unless raw

      idworks_id = first_present(raw, "IDSku", "IDSKU", "idSku", "id_sku", "SkuId", "skuId")
      return nil if idworks_id.blank?

      gallery = fetch_gallery(client, idworks_id)
      target_images = gallery.select { |image| normalized_url(image["Url"]).present? }
      return nil if target_images.empty?

      parent_urls = parent_gallery_urls(client, target_idworks_id: idworks_id)
      own_images = choose_variant_images(target_images, parent_urls)
      urls = own_images.filter_map { |image| normalized_url(image["Url"]) }.uniq
      return nil if urls.empty?

      Result.new(
        found: true,
        sku: sku,
        idworks_id: idworks_id.to_s,
        integration_id: integration.id,
        integration_name: integration.name,
        image_urls: urls,
        images: own_images.map { |image| safe_image_payload(image) },
        errors: []
      )
    end

    def find_exact_sku(client, code)
      body = client.get("sku", {
        "Page" => 0,
        "IDSkuCompany" => code
      })
      exact_match(extract_rows(body), code)
    rescue Integrations::ApiError
      # Alguns tenants antigos têm comportamento inconsistente em filtros do
      # /sku. O fallback pagina a listagem normal e continua exigindo match
      # exato localmente; não transforma erro de filtro em falso "sem imagem".
      find_exact_sku_by_paging(client, code)
    end

    def find_exact_sku_by_paging(client, code)
      0.upto(MAX_FALLBACK_PAGES) do |page|
        rows = extract_rows(client.get("sku", "Page" => page))
        return nil if rows.empty?

        found = exact_match(rows, code)
        return found if found
      end

      nil
    end

    def exact_match(rows, code)
      Array(rows).find do |row|
        value = first_present(row, "IDSkuCompany", "Sku", "SKU", "sku")
        value.to_s.strip.casecmp?(code.to_s.strip)
      end
    end

    def fetch_gallery(client, idworks_id)
      extract_rows(client.get("sku/image/#{idworks_id}"))
        .select { |image| image.is_a?(Hash) }
        .sort_by { |image| [ image["ImageOrder"].to_i, image["IDImage"].to_i ] }
    end

    def parent_gallery_urls(client, target_idworks_id:)
      parent_code = parent_product&.sku.to_s.strip
      return [] if parent_code.blank? || parent_code.casecmp?(sku)

      parent_raw = find_exact_sku(client, parent_code)
      return [] unless parent_raw

      parent_id = first_present(parent_raw, "IDSku", "IDSKU", "idSku", "id_sku", "SkuId", "skuId")
      return [] if parent_id.blank? || parent_id.to_s == target_idworks_id.to_s

      fetch_gallery(client, parent_id)
        .filter_map { |image| normalized_url(image["Url"]) }
        .uniq
    rescue Integrations::ApiError
      []
    end

    def choose_variant_images(target_images, parent_urls)
      # A rota /sku/image/:idsku já é específica do SKU. A comparação com o
      # pai adiciona uma segunda proteção contra imagens compartilhadas.
      if parent_urls.any?
        exclusive = target_images.reject do |image|
          parent_urls.include?(normalized_url(image["Url"]))
        end
        return exclusive if exclusive.any?
      end

      # Em tenants que sinalizam imagem de produto compartilhada, prefere as
      # linhas não marcadas como ProductImage. Não exige esse campo porque ele
      # não é garantido em todas as respostas da API.
      explicitly_variant = target_images.select do |image|
        image.key?("ProductImage") && image["ProductImage"].to_i != 1
      end
      return explicitly_variant if explicitly_variant.any?

      # Se não há galeria do pai para comparar nem sinalização no payload,
      # usamos a própria galeria retornada pelo endpoint específico do SKU.
      target_images
    end

    def extract_rows(body)
      return body if body.is_a?(Array)
      return [] unless body.is_a?(Hash)

      %w[Data data Items items Records records Results results List list Rows rows SKUs skus Images images].each do |key|
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

    def normalized_url(value)
      url = value.to_s.strip
      return nil unless url.match?(%r{\Ahttps://}i)

      url
    end

    def safe_image_payload(image)
      {
        "id" => image["IDImage"],
        "url" => normalized_url(image["Url"]),
        "name" => image["ImageName"],
        "order" => image["ImageOrder"],
        "main" => image["IsMain"].to_i == 1,
        "product_image" => image["ProductImage"],
        "id_sku" => image["IDSku"],
        "width" => image["ImageWidth"],
        "height" => image["ImageHeight"]
      }.compact
    end

    def safe_error(integration, error)
      {
        integration_id: integration.id,
        integration_name: integration.name,
        error_class: error.class.name,
        message: error.message.to_s.first(300)
      }
    end
  end
end
