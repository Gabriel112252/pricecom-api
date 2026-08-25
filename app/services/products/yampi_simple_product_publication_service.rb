# frozen_string_literal: true

require "uri"

module Products
  # Publica o cadastro como um NOVO produto simples na Yampi, com um único
  # SKU. Este modo é separado do fluxo de variação para que a confirmação do
  # usuário corresponda exatamente ao tipo de escrita que será feita.
  class YampiSimpleProductPublicationService
    PublicationError = YampiProductPublicationService::PublicationError
    PUBLICATION_MODE = "produto_simples"

    def initialize(registration:, publication:)
      @registration = registration
      @publication = publication
      @credential = publication.channel_credential
    end

    def publish!
      validate_destination!
      return publication if published_simple_product?

      publication.update!(
        status: "publishing",
        attempts: publication.attempts + 1,
        last_attempt_at: Time.current,
        error_code: nil,
        error_message: nil,
        metadata: publication.metadata.merge("publication_mode" => PUBLICATION_MODE)
      )

      client = Integrations::YampiCatalogWriteClient.new(credential.credentials)
      return recover_existing_external!(client) if publication.external_variant_id.present?

      parent_listing = parent_listing!
      parent_sku = client.fetch_sku(parent_listing.external_id)
      parent_product_id = remote_parent_product_id(parent_listing, parent_sku)
      parent_product = client.fetch_product(parent_product_id)
      image_urls = registration_image_urls
      raise PublicationError.new("product_image_missing", "Nenhuma imagem foi encontrada para publicar #{registration.sku} na Yampi.") if image_urls.empty?

      # Idempotência: se o SKU já existir em qualquer produto da mesma loja,
      # não cria outro produto com o mesmo código. Apenas adota o cadastro
      # remoto existente e registra que ele NÃO foi criado por este fluxo.
      if (existing_sku = client.find_sku_by_code_global(registration.sku))
        return adopt_existing_remote!(client, existing_sku, image_urls)
      end

      created_product = client.create_product(
        product_payload(
          parent_product: parent_product,
          parent_sku: parent_sku,
          image_urls: image_urls
        )
      )

      product_id = created_product["id"].presence
      created_sku = locate_created_sku(client, created_product, product_id)
      product_id ||= created_sku["product_id"].presence
      sku_id = created_sku["id"].presence

      if product_id.blank? || sku_id.blank?
        raise PublicationError.new(
          "created_product_missing_ids",
          "A Yampi respondeu à criação, mas não foi possível confirmar os IDs do produto e do SKU."
        )
      end

      # Guarda os IDs imediatamente para retries e rollback seguros.
      publication.update!(
        external_product_id: product_id.to_s,
        external_variant_id: sku_id.to_s,
        metadata: publication.metadata.merge(
          "publication_mode" => PUBLICATION_MODE,
          "remote_product_created_by_registration" => true,
          "remote_sku_created_by_registration" => true,
          "source_parent_product_id" => parent_product_id.to_s,
          "source_parent_sku_id" => parent_listing.external_id.to_s,
          "source_image_provider" => registration.metadata["source_image_provider"],
          "source_image_urls" => image_urls,
          "source_image_sku" => registration.metadata["source_image_sku"],
          "source_image_fallback_parent" => registration.metadata["source_image_fallback_parent"] == true,
          "created_blocked_sale" => true,
          "created_stock_qty" => 0
        ).compact
      )

      finalize_remote!(client, created_sku, product_id)
    rescue PublicationError
      raise
    rescue Integrations::AuthenticationError => e
      raise PublicationError.new("yampi_authentication_error", e.message)
    rescue Integrations::RateLimitError => e
      raise PublicationError.new("yampi_rate_limited", e.message)
    rescue Integrations::ApiError => e
      raise PublicationError.new("yampi_api_error", e.message)
    rescue ActiveRecord::RecordInvalid => e
      raise PublicationError.new("pricecom_persistence_error", e.record.errors.full_messages.join(", "))
    end

    # Para produto simples, o rollback remove o PRODUTO remoto inteiro somente
    # quando ele foi criado por este fluxo e ainda não possui pedidos. Se o SKU
    # foi apenas adotado, a Yampi é preservada e removemos apenas o vínculo local.
    def undo!
      validate_destination!
      sku_id = publication.external_variant_id.to_s
      product_id = publication.external_product_id.to_s
      return publication if sku_id.blank? && product_id.blank?

      client = Integrations::YampiCatalogWriteClient.new(credential.credentials)
      created_by_registration = publication.metadata["remote_product_created_by_registration"] == true

      delete_outcome = if created_by_registration && product_id.present?
        remote_sku = sku_id.present? ? client.fetch_sku(sku_id) : nil
        if remote_sku && remote_sku["total_orders"].to_i.positive?
          raise PublicationError.new(
            "remote_product_has_orders",
            "Não é seguro desfazer: o produto simples #{registration.sku} já possui pedido(s) na Yampi."
          )
        end
        client.delete_product(product_id)
      else
        :kept_existing_remote
      end

      previous_metadata = publication.metadata
      ChannelProductListing.where(
        tenant: registration.tenant,
        channel: "yampi",
        channel_credential: credential,
        external_id: sku_id
      ).destroy_all if sku_id.present?

      publication.update!(
        status: "planned",
        external_product_id: nil,
        external_variant_id: nil,
        error_code: nil,
        error_message: nil,
        published_at: nil,
        metadata: previous_metadata.merge(
          "last_external_product_id" => product_id,
          "last_external_variant_id" => sku_id,
          "last_purchase_url" => previous_metadata["purchase_url"],
          "undone_at" => Time.current.iso8601,
          "undo_remote_result" => delete_outcome.to_s
        ).except("purchase_url")
      )

      publication
    rescue Integrations::AuthenticationError => e
      raise PublicationError.new("yampi_authentication_error", e.message)
    rescue Integrations::RateLimitError => e
      raise PublicationError.new("yampi_rate_limited", e.message)
    rescue Integrations::ApiError => e
      raise PublicationError.new("yampi_api_error", e.message)
    end

    private

    attr_reader :registration, :publication, :credential

    def published_simple_product?
      publication.status == "published" &&
        publication.external_variant_id.present? &&
        publication.metadata["publication_mode"] == PUBLICATION_MODE
    end

    def validate_destination!
      unless publication.channel == "yampi"
        raise PublicationError.new("wrong_channel", "Esta publicação não é da Yampi.")
      end
      unless credential && credential.tenant_id == registration.tenant_id && credential.channel == "yampi"
        raise PublicationError.new("invalid_store_connection", "A conexão Yampi da publicação é inválida para este tenant.")
      end
    end

    def parent_listing!
      scope = registration.parent_product.channel_product_listings.where(channel: "yampi")
      listing = scope.find_by(channel_credential_id: credential.id)

      if listing.nil?
        single_connection = registration.tenant.channel_credentials.where(channel: "yampi").limit(2).count == 1
        listing = scope.find_by(channel_credential_id: nil) if single_connection
      end

      return listing if listing

      raise PublicationError.new(
        "parent_listing_missing",
        "O produto-base não possui SKU Yampi na loja #{credential.display_name}; não há referência segura para copiar marca e dados físicos."
      )
    end

    def remote_parent_product_id(listing, parent_sku)
      value = listing.external_product_id.presence || parent_sku["product_id"].presence || listing.raw_payload["product_id"].presence
      return value if value.present?

      raise PublicationError.new("parent_product_id_missing", "Não foi possível identificar o produto-base na Yampi.")
    end

    def product_payload(parent_product:, parent_sku:, image_urls:)
      brand_id = extract_brand_id(parent_product)
      if brand_id.blank?
        raise PublicationError.new(
          "parent_brand_missing",
          "O produto-base da Yampi não retornou brand_id; a API exige marca para criar um produto normal."
        )
      end

      sku_fields = %w[price_cost weight height width length quantity_managed availability_soldout]
      missing = sku_fields.select { |field| !parent_sku.key?(field) || parent_sku[field].nil? }
      if missing.any?
        raise PublicationError.new(
          "parent_sku_incomplete",
          "O SKU-base não trouxe os campos necessários para criar o produto normal: #{missing.join(', ')}."
        )
      end

      payload = {
        simple: true,
        brand_id: brand_id.to_i,
        active: true,
        searchable: parent_product.key?("searchable") ? parent_product["searchable"] : true,
        is_digital: parent_product.key?("is_digital") ? parent_product["is_digital"] : false,
        name: registration.name,
        skus: [
          {
            sku: registration.sku,
            price_cost: parent_sku["price_cost"],
            price_sale: registration.price_cents.to_d.fdiv(100),
            weight: parent_sku["weight"],
            height: parent_sku["height"],
            width: parent_sku["width"],
            length: parent_sku["length"],
            quantity_managed: parent_sku["quantity_managed"],
            availability: 0,
            availability_soldout: parent_sku["availability_soldout"],
            # Nasce bloqueado e sem estoque: o MCP entrega o link de compra,
            # mas não abre venda acidental antes da revisão/configuração.
            blocked_sale: true,
            images: image_urls.map { |url| { url: url } }
          }
        ]
      }

      copy_optional_product_fields!(payload, parent_product)
      categories = extract_relation_ids(parent_product["categories"])
      payload[:categories_ids] = categories if categories.any?
      payload
    end

    def copy_optional_product_fields!(payload, parent_product)
      %w[description specifications measures ncm warranty].each do |field|
        value = parent_product[field]
        payload[field.to_sym] = value unless value.nil? || value == ""
      end
    end

    def extract_brand_id(product)
      product["brand_id"] ||
        product.dig("brand", "id") ||
        product.dig("brand", "data", "id")
    end

    def extract_relation_ids(value)
      rows = case value
      when Array then value
      when Hash then Array(value["data"])
      else []
      end
      rows.filter_map { |row| row.is_a?(Hash) ? row["id"] : nil }.compact.uniq
    end

    def locate_created_sku(client, created_product, product_id)
      nested = Array(created_product["skus"]).find { |row| row.is_a?(Hash) && row["sku"].to_s.casecmp?(registration.sku) }
      return nested if nested && nested["id"].present?

      if product_id.present?
        within_product = client.find_sku_by_code(product_id: product_id, sku: registration.sku)
        return within_product if within_product
      end

      found = client.find_sku_by_code_global(registration.sku)
      return found if found

      raise PublicationError.new("created_sku_not_found", "O produto foi criado, mas o SKU #{registration.sku} não foi localizado na confirmação.")
    end

    def adopt_existing_remote!(client, remote_sku, image_urls)
      sku_id = remote_sku["id"].presence
      product_id = remote_sku["product_id"].presence
      if sku_id.blank? || product_id.blank?
        raise PublicationError.new("existing_sku_missing_ids", "A Yampi encontrou o SKU, mas não retornou os IDs necessários.")
      end

      publication.update!(
        external_product_id: product_id.to_s,
        external_variant_id: sku_id.to_s,
        metadata: publication.metadata.merge(
          "publication_mode" => PUBLICATION_MODE,
          "remote_product_created_by_registration" => false,
          "remote_sku_created_by_registration" => false,
          "remote_sku_adopted_at" => Time.current.iso8601,
          "source_image_urls" => image_urls
        )
      )

      finalize_remote!(client, remote_sku, product_id)
    end

    def recover_existing_external!(client)
      remote_sku = client.fetch_sku(publication.external_variant_id)
      product_id = publication.external_product_id.presence || remote_sku["product_id"].presence
      raise PublicationError.new("remote_product_id_missing", "O SKU já criado não retornou product_id.") if product_id.blank?

      finalize_remote!(client, remote_sku, product_id, recovered: true)
    end

    def finalize_remote!(client, sku, product_id, recovered: false)
      sku_id = sku["id"] || publication.external_variant_id
      raise PublicationError.new("remote_sku_missing_id", "A Yampi não retornou o ID do SKU.") if sku_id.blank?

      image_count = ensure_remote_images!(client, sku_id)
      hydrated = client.fetch_sku(sku_id)
      sku = sku.merge(hydrated) if hydrated.is_a?(Hash)
      purchase_url = sku["purchase_url"].presence

      persist_listing!(sku, product_id)
      publication.update!(
        status: "published",
        external_product_id: product_id.to_s,
        external_variant_id: sku_id.to_s,
        error_code: nil,
        error_message: nil,
        published_at: publication.published_at || Time.current,
        metadata: publication.metadata.merge(
          "publication_mode" => PUBLICATION_MODE,
          "purchase_url" => purchase_url,
          "remote_images_verified" => true,
          "remote_image_count" => image_count,
          "recovered_after_partial_persistence" => recovered
        ).compact
      )

      publication
    end

    def ensure_remote_images!(client, sku_id)
      images = client.sku_images(sku_id)
      if images.empty?
        client.create_sku_images(sku_id: sku_id, urls: registration_image_urls)
        images = client.sku_images(sku_id)
      end

      if images.empty?
        raise PublicationError.new(
          "yampi_image_not_confirmed",
          "O produto existe na Yampi, mas nenhuma imagem foi confirmada. A publicação ficou pendente para retry."
        )
      end

      images.size
    end

    def registration_image_urls
      urls = Array(registration.metadata["source_image_urls"])
        .map { |url| normalized_https_url(url) }
        .compact

      if registration.images.attached?
        base = URI.parse(ENV.fetch("APP_HOST", "https://pricecom-pricecom-api.dzxtro.easypanel.host"))
        options = { host: base.host, protocol: base.scheme }
        options[:port] = base.port unless [ 80, 443 ].include?(base.port)
        urls.concat(registration.images.map { |image| Rails.application.routes.url_helpers.rails_blob_url(image, **options) })
      end

      urls.compact.uniq
    end

    def normalized_https_url(value)
      url = value.to_s.strip
      return nil unless url.match?(%r{\Ahttps://}i)

      url
    end

    def persist_listing!(remote_sku, product_id)
      sku_id = remote_sku["id"] || publication.external_variant_id
      raise PublicationError.new("remote_sku_missing_id", "A Yampi não retornou o ID do SKU.") if sku_id.blank?

      listing = ChannelProductListing.find_or_initialize_by(
        tenant: registration.tenant,
        channel_credential: credential,
        external_id: sku_id.to_s
      )
      listing.channel = "yampi"
      listing.product = registration.product
      listing.external_sku = registration.sku
      listing.stock_qty = remote_sku["total_in_stock"] || remote_sku["availability"] || 0
      listing.price = remote_sku["price_sale"] || registration.price_cents.to_d.fdiv(100)
      listing.raw_payload = remote_sku
      listing.synced_at = Time.current
      listing.external_product_id = product_id.to_s
      listing.remote_status = remote_sku["blocked_sale"] == false ? "selling" : "platform_blocked"
      listing.remote_status_reason = "simple_product_registration"
      listing.remote_status_metadata = { "source" => "mcp_product_registration", "mode" => PUBLICATION_MODE }
      listing.remote_status_synced_at = Time.current
      listing.selling_status = remote_sku["blocked_sale"] == false ? "selling" : "platform_blocked"
      listing.selling_enabled = remote_sku["blocked_sale"] == false
      listing.replenishment_eligible = false
      listing.save!
    end
  end
end
