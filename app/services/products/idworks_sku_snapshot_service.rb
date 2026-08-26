# frozen_string_literal: true

module Products
  # Lê o SKU exato diretamente no IDWorks para a publicação de catálogo.
  # Diferente do resolver de imagens, este serviço não exige galeria: kits
  # como 2142_2 podem existir normalmente no ERP mesmo sem imagem própria.
  class IdworksSkuSnapshotService
    Result = Struct.new(
      :found,
      :sku,
      :idworks_id,
      :integration_id,
      :integration_name,
      :raw,
      :errors,
      keyword_init: true
    ) do
      def found? = found == true

      def quantity_available
        decimal(raw && raw["QtyAvailable"])&.floor
      end

      def cost_average
        decimal(raw && (raw["CostAverage"].presence || raw["CostLastPurchase"]))
      end

      def weight = decimal(raw && raw["SkuWeight"])
      def height = decimal(raw && raw["SkuHeight"])
      def width = decimal(raw && raw["SkuWidth"])
      def length = decimal(raw && raw["SkuLength"])
      def ncm = raw && raw["SkuNCM"].to_s.strip.presence
      def type_product = raw && raw["TypeProduct"].to_s.strip.presence
      def name = raw && raw["SkuName"].to_s.strip.presence

      private

      def decimal(value)
        return nil if value.nil? || value == ""

        BigDecimal(value.to_s)
      rescue ArgumentError
        nil
      end
    end

    MAX_FALLBACK_PAGES = 50

    def initialize(tenant:, sku:, preferred_integration: nil)
      @tenant = tenant
      @sku = sku.to_s.strip
      @preferred_integration = preferred_integration
    end

    def call
      errors = []

      candidate_integrations.each do |integration|
        begin
          client = Integrations::Idworks::BaseClient.new(integration.credentials)
          client.authenticate!
          raw = find_exact_sku(client, sku)
          next unless raw

          idworks_id = first_present(raw, "IDSku", "IDSKU", "idSku", "id_sku", "SkuId", "skuId")
          return Result.new(
            found: true,
            sku: sku,
            idworks_id: idworks_id&.to_s,
            integration_id: integration.id,
            integration_name: integration.name,
            raw: raw,
            errors: errors
          )
        rescue Integrations::AuthenticationError,
               Integrations::RateLimitError,
               Integrations::ApiError => e
          errors << safe_error(integration, e)
        rescue => e
          errors << safe_error(integration, e)
        end
      end

      Result.new(found: false, sku: sku, raw: nil, errors: errors)
    end

    private

    attr_reader :tenant, :sku, :preferred_integration

    def candidate_integrations
      preferred = Array(preferred_integration).compact.select do |integration|
        integration.provider == "idworks" && integration.tenant_id == tenant.id
      end
      others = tenant.integrations.where(provider: "idworks").order(:id).to_a

      (preferred + others).select(&:credentials_configured?).uniq(&:id)
    end

    def find_exact_sku(client, code)
      body = client.get("sku", "Page" => 0, "IDSkuCompany" => code)
      exact_match(extract_rows(body), code) || find_exact_sku_by_paging(client, code)
    rescue Integrations::ApiError
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
        next false unless row.is_a?(Hash)

        value = first_present(row, "IDSkuCompany", "Sku", "SKU", "sku")
        value.to_s.strip.casecmp?(code.to_s.strip)
      end
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
