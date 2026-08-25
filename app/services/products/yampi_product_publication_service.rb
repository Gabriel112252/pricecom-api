# frozen_string_literal: true

require "uri"

module Products
  class YampiProductPublicationService
    class PublicationError < StandardError
      attr_reader :code

      def initialize(code, message)
        @code = code
        super(message)
      end
    end

    def initialize(registration:, publication:)
      @registration = registration
      @publication = publication
      @credential = publication.channel_credential
    end

    def publish!
      validate_destination!
      return publication if publication.status == "published" && publication.external_variant_id.present?

      publication.update!(
        status: "publishing",
        attempts: publication.attempts + 1,
        last_attempt_at: Time.current,
        error_code: nil,
        error_message: nil
      )

      parent_listing = parent_listing!
      client = Integrations::YampiCatalogWriteClient.new(credential.credentials)
      return recover_existing_external!(client) if publication.external_variant_id.present?

      parent_sku = client.fetch_sku(parent_listing.external_id)
      product_id = remote_product_id(parent_listing, parent_sku)
      image_urls = registration_image_urls
      if image_urls.empty?
        raise PublicationError.new(
          "variation_image_missing",
          "A publicação foi bloqueada porque não foi encontrada imagem própria da variação #{registration.sku}."
        )
      end

      # Mesmo SKU em outro canal é o mesmo Product do Pricecom. E se ele já
      # existir também na Yampi, adotamos o SKU remoto em vez de inventar
      # outro código ou duplicá-lo.
      existing_remote = client.find_sku_by_code(product_id: product_id, sku: registration.sku)
      return adopt_existing_remote!(client, existing_remote, product_id, image_urls) if existing_remote

      axis = YampiVariationAxisService.new(
        client: client,
        registration: registration,
        parent_sku: parent_sku,
        product_id: product_id
      ).call

      created_sku = client.create_sku(
        sku_payload(
          parent_sku: parent_sku,
          product_id: product_id,
          variation_value_name: axis.target_value_name,
          image_urls: image_urls
        )
      )

      sku_id = created_sku["id"]
      raise PublicationError.new("created_sku_missing_id", "A Yampi criou o SKU, mas não retornou o ID externo.") if sku_id.blank?

      # Guarda os IDs logo depois do POST. Se a etapa de imagem/leitura do
      # link falhar, o retry recupera este mesmo SKU em vez de criar outro.
      publication.update!(
        external_product_id: product_id.to_s,
        external_variant_id: sku_id.to_s,
        metadata: publication.metadata.merge(
          "remote_sku_created_by_registration" => true,
          "variation_id" => axis.variation_id,
          "variation_name" => axis.variation_name,
          "variation_value_id" => axis.target_value_id,
          "variation_value_name" => axis.target_value_name,
          "variation_value_created" => axis.target_value_created,
          "converted_product_from_simple" => axis.converted_from_simple,
          "base_variation_value_id" => axis.base_value_id,
          "base_variation_value_name" => axis.base_value_name,
          "parent_external_variant_id" => parent_listing.external_id.to_s,
          "created_blocked_sale" => true,
          "created_stock_qty" => 0,
          "source_image_provider" => registration.metadata["source_image_provider"],
          "source_image_urls" => image_urls,
          "source_image_idworks_id" => registration.metadata["source_image_idworks_id"]
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

    # Remove da Yampi apenas SKUs que ESTE fluxo criou. Quando a publicação
    # adotou um SKU remoto preexistente, desfazer remove só o vínculo local.
    def undo!
      validate_destination!
      sku_id = publication.external_variant_id.to_s
      return publication if sku_id.blank?

      created_by_registration = publication.metadata["remote_sku_created_by_registration"] != false
      delete_outcome = if created_by_registration
        Integrations::YampiCatalogWriteClient.new(credential.credentials).delete_sku(sku_id)
      else
        :kept_existing_remote
      end

      previous_metadata = publication.metadata
      ChannelProductListing.where(
        tenant: registration.tenant,
        channel: "yampi",
        channel_credential: credential,
        external_id: sku_id
      ).destroy_all

      publication.update!(
        status: "planned",
        external_product_id: nil,
        external_variant_id: nil,
        error_code: nil,
        error_message: nil,
        published_at: nil,
        metadata: previous_metadata.merge(
          "last_external_product_id" => publication.external_product_id,
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
        "O produto-base não possui um SKU Yampi na loja #{credential.display_name}."
      )
    end

    def adopt_existing_remote!(client, remote_sku, product_id, image_urls)
      sku_id = remote_sku["id"]
      raise PublicationError.new("existing_sku_missing_id", "A Yampi encontrou o SKU, mas não retornou o ID.") if sku_id.blank?

      hydrated = client.fetch_sku(sku_id)
      remote_sku = remote_sku.merge(hydrated) if hydrated.is_a?(Hash)

      publication.update!(
        external_product_id: product_id.to_s,
        external_variant_id: sku_id.to_s,
        metadata: publication.metadata.merge(
          "remote_sku_created_by_registration" => false,
          "remote_sku_adopted_at" => Time.current.iso8601,
          "source_image_provider" => registration.metadata["source_image_provider"],
          "source_image_urls" => image_urls,
          "source_image_idworks_id" => registration.metadata["source_image_idworks_id"]
        ).compact
      )

      finalize_remote!(client, remote_sku, product_id)
    end

    def recover_existing_external!(client)
      remote_sku = client.fetch_sku(publication.external_variant_id)
      product_id = publication.external_product_id.presence || remote_sku["product_id"].presence
      if product_id.blank?
        raise PublicationError.new("parent_product_id_missing", "O SKU já criado não retornou product_id na recuperação.")
      end

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
          "purchase_url" => purchase_url,
          "remote_images_verified" => true,
          "remote_image_count" => image_count,
          "recovered_after_partial_persistence" => recovered
        ).compact
      )

      publication
    end

    # O POST de criação de SKU aceita images, mas a Yampi também tem um
    # endpoint próprio de imagens. Confirmamos a galeria e, se o create não
    # tiver processado nenhuma, fazemos o upload por URL usando a mesma arte
    # que veio do IDWorks. Só concluímos a publicação com pelo menos 1 imagem.
    def ensure_remote_images!(client, sku_id)
      images = client.sku_images(sku_id)
      if images.empty?
        source_urls = registration_image_urls
        client.create_sku_images(sku_id: sku_id, urls: source_urls)
        images = client.sku_images(sku_id)
      end

      if images.empty?
        raise PublicationError.new(
          "yampi_image_not_confirmed",
          "O SKU existe na Yampi, mas nenhuma imagem foi confirmada. A publicação ficou pendente para retry."
        )
      end

      images.size
    end

    def remote_product_id(listing, parent_sku)
      value = listing.external_product_id.presence || parent_sku["product_id"].presence || listing.raw_payload["product_id"].presence
      return value if value.present?

      raise PublicationError.new("parent_product_id_missing", "Não foi possível identificar o product_id do produto-base na Yampi.")
    end

    def sku_payload(parent_sku:, product_id:, variation_value_name:, image_urls:)
      required = %w[price_cost weight height width length quantity_managed availability_soldout]
      missing = required.select { |field| !parent_sku.key?(field) || parent_sku[field].nil? }
      if missing.any?
        raise PublicationError.new(
          "parent_sku_incomplete",
          "O SKU-base na Yampi não possui os campos obrigatórios: #{missing.join(', ')}. Nada foi criado."
        )
      end

      {
        product_id: product_id.to_i,
        sku: registration.sku,
        price_cost: parent_sku["price_cost"],
        price_sale: registration.price_cents.to_d.fdiv(100),
        weight: parent_sku["weight"],
        height: parent_sku["height"],
        width: parent_sku["width"],
        length: parent_sku["length"],
        quantity_managed: parent_sku["quantity_managed"],
        availability: 0,
        availability_soldout: 0,
        blocked_sale: true,
        variations_values_ids: [ variation_value_name ],
        images: image_urls.map { |url| { url: url } }
      }.tap do |payload|
        if parent_sku.key?("allow_sell_without_customization")
          payload[:allow_sell_without_customization] = parent_sku["allow_sell_without_customization"]
        end
      end
    end

    def registration_image_urls
      urls = Array(registration.metadata["source_image_urls"])
        .map { |url| normalized_https_url(url) }
        .compact

      if registration.images.attached?
        base = URI.parse(ENV.fetch("APP_HOST", "https://pricecom-pricecom-api.dzxtro.easypanel.host"))
        options = { host: base.host, protocol: base.scheme }
        options[:port] = base.port unless [ 80, 443 ].include?(base.port)

        urls.concat(registration.images.map do |image|
          Rails.application.routes.url_helpers.rails_blob_url(image, **options)
        end)
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
      listing.remote_status_reason = "product_registration"
      listing.remote_status_metadata = { "source" => "mcp_product_registration" }
      listing.remote_status_synced_at = Time.current
      listing.selling_status = remote_sku["blocked_sale"] == false ? "selling" : "platform_blocked"
      listing.selling_enabled = remote_sku["blocked_sale"] == false
      listing.replenishment_eligible = false
      listing.save!
    end
  end
end
