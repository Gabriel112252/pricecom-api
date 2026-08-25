# frozen_string_literal: true

module Integrations
  # Escritas de catálogo usadas pelo fluxo guiado de cadastro de produto.
  # Mantido separado de YampiAdapter para não misturar o sync periódico com
  # operações destrutivas/criativas disparadas por confirmação explícita.
  class YampiCatalogWriteClient
    include AdapterHttp

    BASE_URL = "https://api.dooki.com.br/v2/".freeze
    PER_PAGE = 50

    def initialize(credentials)
      @credentials = credentials.to_h.with_indifferent_access
    end

    def fetch_product(product_id)
      unwrap_record(get(
        "/catalog/products/#{product_id}",
        include: "variations,skus",
        skipCache: true
      ))
    end

    def update_product(product_id, attributes)
      unwrap_record(put("/catalog/products/#{product_id}", attributes))
    end

    def fetch_sku(sku_id)
      unwrap_record(get("/catalog/skus/#{sku_id}", skipCache: true))
    end

    def update_sku(sku_id, attributes)
      unwrap_record(put("/catalog/skus/#{sku_id}", attributes))
    end

    def product_skus(product_id)
      paginate("/catalog/products/#{product_id}/skus")
    end

    def find_sku_by_code(product_id:, sku:)
      target = sku.to_s.strip
      return nil if target.blank?

      product_skus(product_id).find { |row| row["sku"].to_s.casecmp?(target) }
    end

    def variations
      paginate("/catalog/variations")
    end

    def find_or_create_variation(name:)
      normalized_name = name.to_s.strip
      raise ApiError, "Nome da variação não pode ficar em branco." if normalized_name.blank?

      existing = variations.find do |row|
        row["name"].to_s.strip.casecmp?(normalized_name)
      end
      return [ existing, false ] if existing

      created = unwrap_record(post("/catalog/variations", { name: normalized_name }))
      [ created, true ]
    end

    def variation_values(variation_id)
      paginate("/catalog/variations/#{variation_id}/values")
    end

    def find_or_create_variation_value(variation_id:, name:)
      normalized_name = name.to_s.strip
      raise ApiError, "Nome da variação não pode ficar em branco." if normalized_name.blank?

      existing = variation_values(variation_id).find do |row|
        row["name"].to_s.strip.casecmp?(normalized_name)
      end
      return [ existing, false ] if existing

      created = unwrap_record(post("/catalog/variations/#{variation_id}/values", { name: normalized_name }))
      [ created, true ]
    end

    def create_sku(attributes)
      unwrap_record(post("/catalog/skus", attributes))
    end

    def create_sku_images(sku_id:, urls:, upload_option: "resize")
      normalized_urls = Array(urls).map(&:to_s).map(&:strip).reject(&:blank?).uniq
      return [] if normalized_urls.empty?

      body = post("/catalog/skus/#{sku_id}/images", {
        images: normalized_urls.map { |url| { url: url } },
        upload_option: upload_option
      })
      Array(body.is_a?(Hash) ? body["data"] : body)
    end

    # Retorna :deleted ou :already_absent. DELETE /catalog/skus/{id} é o
    # rollback oficial da API Yampi; 404 é tratado como sucesso idempotente.
    def delete_sku(sku_id)
      response = connection(BASE_URL).delete(alias_path("/catalog/skus/#{sku_id}")) do |req|
        apply_auth(req)
      end
      return :already_absent if response.status == 404

      handle_response(response)
      :deleted
    end

    # Usado apenas para compensar uma criação de valor quando a criação do
    # SKU falha antes de existir qualquer publicação externa persistida.
    def delete_variation_value(variation_id:, value_id:)
      response = connection(BASE_URL).delete(alias_path("/catalog/variations/#{variation_id}/values/#{value_id}")) do |req|
        apply_auth(req)
      end
      return :already_absent if response.status == 404

      handle_response(response)
      :deleted
    end

    private

    attr_reader :credentials

    def paginate(path)
      records = []
      page = 1

      loop do
        body = get(path, page: page, per_page: PER_PAGE, skipCache: true)
        page_records = Array(body["data"])
        records.concat(page_records)

        pagination = body.dig("meta", "pagination") || body.dig("meta", "meta", "pagination") || {}
        total_pages = pagination["total_pages"].to_i
        break if page_records.empty? || total_pages <= page || total_pages.zero?

        page += 1
      end

      records
    end

    def get(path, **params)
      response = connection(BASE_URL).get(alias_path(path), params) { |req| apply_auth(req) }
      handle_response(response)
    end

    def post(path, body)
      response = connection(BASE_URL).post(alias_path(path)) do |req|
        apply_auth(req)
        req.body = body
      end
      handle_response(response)
    end

    def put(path, body)
      response = connection(BASE_URL).put(alias_path(path)) do |req|
        apply_auth(req)
        req.body = body
      end
      handle_response(response)
    end

    def apply_auth(request)
      request.headers["User-Token"] = credentials[:token]
      request.headers["User-Secret-Key"] = credentials[:secret_key]
    end

    def alias_path(path)
      store_alias = credentials[:alias].to_s.strip
      raise AuthenticationError, "Yampi: alias da loja não configurado." if store_alias.blank?

      "#{store_alias}#{path}"
    end

    def unwrap_record(body)
      return body unless body.is_a?(Hash)

      data = body["data"]
      return data.first if data.is_a?(Array) && data.one?
      return data if data.is_a?(Hash)

      body
    end
  end
end
