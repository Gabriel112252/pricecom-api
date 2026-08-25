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

      listing = parent_listing!
      client = Integrations::YampiCatalogWriteClient.new(credential.credentials)
      parent_sku = client.fetch_sku(listing.external_id)
      product_id = remote_product_id(listing, parent_sku)

      if client.find_sku_by_code(product_id: product_id, sku: registration.sku)
        raise PublicationError.new(
          "remote_sku_already_exists",
          "Já existe o SKU #{registration.sku} neste produto da Yampi. Nada foi criado para evitar duplicidade."
        )
      end

      variation = single_variation!(parent_sku)
      variation_id = variation.fetch("id")
      variation_value, variation_value_created = client.find_or_create_variation_value(
        variation_id: variation_id,
        name: registration.name
      )
      variation_value_id = variation_value["id"]
      variation_value_name = variation_value["name"].presence || registration.name
      raise PublicationError.new("variation_value_missing_id", "A Yampi não retornou o ID do valor de variação.") if variation_value_id.blank?

      created_sku = nil
      begin
        created_sku = client.create_sku(
          sku_payload(
            parent_sku: parent_sku,
            product_id: product_id,
            variation_value_name: variation_value_name
          )
        )
      rescue => e
        compensate_variation_value(client, variation_id, variation_value_id) if variation_value_created
        raise e
      end

      sku_id = created_sku["id"]
      raise PublicationError.new("created_sku_missing_id", "A Yampi criou o SKU, mas não retornou o ID externo.") if sku_id.blank?

      persist_listing!(created_sku, product_id)
      publication.update!(
        status: "published",
        external_product_id: product_id.to_s,
        external_variant_id: sku_id.to_s,
        error_code: nil,
        error_message: nil,
        published_at: Time.current,
        metadata: publication.metadata.merge(
          "purchase_url" => created_sku["purchase_url"],
          "variation_id" => variation_id,
          "variation_value_id" => variation_value_id,
          "variation_value_name" => variation_value_name,
          "variation_value_created" => variation_value_created,
          "parent_external_variant_id" => listing.external_id.to_s,
          "created_blocked_sale" => true,
          "created_stock_qty" => 0
        ).compact
      )

      publication
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

    # Desfaz somente o SKU que esta publicação criou. O valor da variação
    # não é removido aqui: depois de publicado ele pode ter passado a ser
    # usado por outro SKU, então apagá-lo automaticamente seria destrutivo.
    def undo!
      validate_destination!
      sku_id = publication.external_variant_id.to_s
      return publication if sku_id.blank?

      client = Integrations::YampiCatalogWriteClient.new(credential.credentials)
      delete_outcome = client.delete_sku(sku_id)
      previous_metadata = publication.metadata

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

    def remote_product_id(listing, parent_sku)
      value = listing.external_product_id.presence || parent_sku["product_id"].presence || listing.raw_payload["product_id"].presence
      return value if value.present?

      raise PublicationError.new("parent_product_id_missing", "Não foi possível identificar o product_id do produto-base na Yampi.")
    end

    def single_variation!(parent_sku)
      variations = Array(parent_sku["variations"])
      if variations.empty?
        raise PublicationError.new(
          "parent_has_no_variation_axis",
          "O produto-base da Yampi é simples e não possui eixo de variação. Nada foi criado."
        )
      end
      if variations.size != 1
        raise PublicationError.new(
          "multiple_variation_axes_not_supported",
          "O produto-base possui #{variations.size} eixos de variação. O cadastro MCP atual aceita somente um eixo para não adivinhar combinações."
        )
      end

      variation = variations.first
      return variation if variation["id"].present?

      raise PublicationError.new("variation_id_missing", "A Yampi não retornou o ID do eixo de variação do produto-base.")
    end

    def sku_payload(parent_sku:, product_id:, variation_value_name:)
      required = %w[price_cost weight height width length quantity_managed]
      missing = required.select { |field| !parent_sku.key?(field) || parent_sku[field].nil? }
      if missing.any?
        raise PublicationError.new(
          "parent_sku_incomplete",
          "O SKU-base na Yampi não possui os campos obrigatórios: #{missing.join(', ')}. Nada foi criado."
        )
      end

      payload = {
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
        # A documentação Yampi tipa este campo como string[] e mostra os
        # nomes dos valores (ex.: "Amarelo", "M"), apesar do sufixo _ids.
        variations_values_ids: [ variation_value_name ]
      }

      if parent_sku.key?("allow_sell_without_customization")
        payload[:allow_sell_without_customization] = parent_sku["allow_sell_without_customization"]
      end

      images = registration_image_urls
      payload[:images] = images.map { |url| { url: url } } if images.any?
      payload
    end

    def registration_image_urls
      return [] unless registration.images.attached?

      base = URI.parse(ENV.fetch("APP_HOST", "https://pricecom-pricecom-api.dzxtro.easypanel.host"))
      options = { host: base.host, protocol: base.scheme }
      options[:port] = base.port unless [ 80, 443 ].include?(base.port)

      registration.images.map do |image|
        Rails.application.routes.url_helpers.rails_blob_url(image, **options)
      end
    end

    def compensate_variation_value(client, variation_id, variation_value_id)
      client.delete_variation_value(variation_id: variation_id, value_id: variation_value_id)
    rescue => e
      Rails.logger.warn(
        "[YampiProductPublicationService] compensation failed variation_id=#{variation_id} " \
        "value_id=#{variation_value_id}: #{e.message}"
      )
    end

    def persist_listing!(created_sku, product_id)
      listing = ChannelProductListing.find_or_initialize_by(
        tenant: registration.tenant,
        channel_credential: credential,
        external_id: created_sku.fetch("id").to_s
      )
      listing.channel = "yampi"
      listing.product = registration.product
      listing.external_sku = registration.sku
      listing.stock_qty = created_sku["total_in_stock"] || created_sku["availability"] || 0
      listing.price = created_sku["price_sale"] || registration.price_cents.to_d.fdiv(100)
      listing.raw_payload = created_sku
      listing.synced_at = Time.current
      listing.external_product_id = product_id.to_s
      listing.remote_status = "platform_blocked"
      listing.remote_status_reason = "created_by_product_registration"
      listing.remote_status_metadata = { "source" => "mcp_product_registration" }
      listing.remote_status_synced_at = Time.current
      listing.selling_status = "platform_blocked"
      listing.selling_enabled = false
      listing.replenishment_eligible = false
      listing.save!
    end
  end
end
