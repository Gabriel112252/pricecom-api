# frozen_string_literal: true

module Products
  # Resolve a imagem da VARIAÇÃO/SKU diretamente no IDWorks, sem depender
  # de Product#idworks_id estar sincronizado no Pricecom.
  #
  # A API pública do IDWorks oferece:
  #   GET /sku?IDSkuCompanyStrict=<sku>  -> localiza o SKU pelo código exato
  #   GET /sku/image/:idsku              -> galeria ordenada do SKU
  #
  # Isso é importante para cadastros como 2142_2 / 2142_3: a arte correta
  # está no SKU da quantidade correspondente e não deve ser herdada
  # silenciosamente do produto-base.
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

      (preferred + others)
        .select(&:credentials_configured?)
        .uniq(&:id)
    end

    def resolve_from(integration)
      client = Integrations::Idworks::BaseClient.new(integration.credentials)
      client.authenticate!

      body = client.get("sku", {
        "Page" => 0,
        "IDSkuCompanyStrict" => sku
      })

      raw = extract_rows(body).find do |row|
        value = first_present(row, "IDSkuCompany", "Sku", "SKU", "sku")
        value.to_s.casecmp?(sku)
      end
      return nil unless raw

      idworks_id = first_present(raw, "IDSku", "IDSKU", "idSku", "id_sku", "SkuId", "skuId")
      return nil if idworks_id.blank?

      gallery = Array(client.get("sku/image/#{idworks_id}"))
        .select { |image| image.is_a?(Hash) }
        .sort_by { |image| [ image["ImageOrder"].to_i, image["IDImage"].to_i ] }

      # Quando ShareProductImage=1, o endpoint também pode devolver imagens
      # do produto-pai com ProductImage=1. Para publicação automática não
      # usamos essas imagens se o SKU alvo deveria ter uma arte própria.
      own_images = gallery.select do |image|
        image["IDSku"].to_s == idworks_id.to_s && image["ProductImage"].to_i != 1
      end

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

    def extract_rows(body)
      return body if body.is_a?(Array)
      return [] unless body.is_a?(Hash)

      %w[Data data Items items Records records Results results List list Rows rows SKUs skus].each do |key|
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
