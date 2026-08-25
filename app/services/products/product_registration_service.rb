module Products
  class ProductRegistrationService
    class ValidationError < StandardError
      attr_reader :errors

      def initialize(errors)
        @errors = Array(errors)
        super(@errors.join(", "))
      end
    end

    CHANNEL_LABELS = {
      "shopify" => "Shopify",
      "yampi" => "Yampi",
      "tiktok" => "TikTok Shop",
      "nuvemshop" => "Nuvemshop",
      "idworks" => "IDWorks"
    }.freeze

    def initialize(tenant:, user: nil)
      @tenant = tenant
      @user = user
    end

    def create_draft!(attributes)
      attrs = attributes.to_h.with_indifferent_access
      parent = tenant.products.find(attrs[:parent_product_id])

      registration = ProductRegistration.new(
        tenant: tenant,
        parent_product: parent,
        created_by_user: user,
        sku: attrs[:sku].to_s.strip,
        name: attrs[:name].to_s.strip,
        price_cents: parse_price_cents(attrs[:price_cents])
      )

      ProductRegistration.transaction do
        registration.save!
        sync_publications!(
          registration,
          channels: attrs[:channels],
          channel_credential_ids: attrs[:channel_credential_ids]
        )
      end

      # Não mantém transação de banco aberta enquanto consulta o ERP.
      sync_idworks_images!(registration, force: true)
      refresh_validation_state!(registration)
      registration.reload
    end

    def update_draft!(registration, attributes)
      ensure_same_tenant!(registration)
      if registration.product_id.present?
        raise ValidationError, [ "O produto já foi vinculado no Pricecom e o rascunho não pode mais alterar seus dados-base." ]
      end

      attrs = attributes.to_h.with_indifferent_access
      sku_changed = attrs.key?(:sku) && registration.sku.to_s != attrs[:sku].to_s.strip

      ProductRegistration.transaction do
        if attrs[:parent_product_id].present?
          registration.parent_product = tenant.products.find(attrs[:parent_product_id])
        end
        registration.sku = attrs[:sku].to_s.strip if attrs.key?(:sku)
        registration.name = attrs[:name].to_s.strip if attrs.key?(:name)
        registration.price_cents = parse_price_cents(attrs[:price_cents]) if attrs.key?(:price_cents)
        registration.save!

        if attrs.key?(:channels) || attrs.key?(:channel_credential_ids)
          sync_publications!(
            registration,
            channels: attrs[:channels],
            channel_credential_ids: attrs[:channel_credential_ids]
          )
        end
      end

      sync_idworks_images!(registration, force: sku_changed)
      refresh_validation_state!(registration)
      registration.reload
    end

    # O SKU do Pricecom é uma identidade global do produto entre canais.
    # Se a nova variação já existe internamente (ex.: 2142_2 vindo do TikTok),
    # ela é REUTILIZADA e recebe apenas um novo listing Yampi. Não se cria um
    # segundo Product com o mesmo SKU e não se inventa um SKU alternativo.
    def publish!(registration)
      ensure_same_tenant!(registration)
      registration.reload

      # Também roda aqui para recuperar rascunhos criados antes da rotina de
      # imagens existir (por exemplo um draft antigo bloqueado por SKU duplicado).
      sync_idworks_images!(registration)

      if registration.product_id.blank?
        errors = validation_messages(registration)
        if errors.any?
          registration.update!(status: "draft", validation_errors: errors)
          raise ValidationError, errors
        end

        ensure_local_product!(registration)
      end

      process_publications!(registration.reload)
      refresh_publication_state!(registration)
      registration.reload
    rescue ActiveRecord::RecordInvalid => e
      errors = e.record.errors.full_messages.presence || [ e.message ]
      registration.update_columns(
        status: "failed",
        validation_errors: errors,
        updated_at: Time.current
      ) if registration.persisted?
      raise ValidationError, errors
    rescue ActiveRecord::RecordNotUnique
      errors = [ "Conflito ao vincular o SKU no Pricecom. Recarregue o cadastro e tente novamente." ]
      registration.update_columns(
        status: "failed",
        validation_errors: errors,
        updated_at: Time.current
      ) if registration.persisted?
      raise ValidationError, errors
    end

    # Rollback explícito do cadastro guiado. Primeiro desfaz publicações
    # externas. O Product local só é removido quando ELE FOI CRIADO por este
    # cadastro; um Product pré-existente (ex.: já usado no TikTok) permanece.
    def undo!(registration)
      ensure_same_tenant!(registration)
      registration.reload

      product = registration.product
      created_local_product = local_product_created_by_registration?(registration)

      if created_local_product && product&.order_items&.exists?
        raise ValidationError, [
          "Não é seguro desfazer: o produto #{product.sku} criado por este cadastro já está vinculado a pedido(s)."
        ]
      end

      unsupported_published = registration.publications.select do |publication|
        publication.channel != "yampi" && publication.status == "published" && publication.external_variant_id.present?
      end
      if unsupported_published.any?
        raise ValidationError, [
          "Não é seguro desfazer enquanto houver publicação externa concluída em outro canal."
        ]
      end

      registration.publications.includes(:channel_credential).select do |publication|
        publication.channel == "yampi" && publication.external_variant_id.present?
      end.each do |publication|
        YampiProductPublicationService.new(
          registration: registration,
          publication: publication
        ).undo!
      rescue YampiProductPublicationService::PublicationError => e
        registration.update!(status: "partial_failure") if registration.product_id.present?
        raise ValidationError, [ "Falha ao desfazer #{destination_label(publication)}: #{e.message}" ]
      end

      ProductRegistration.transaction do
        registration.lock!
        product = registration.product

        registration.publications.each do |publication|
          next if publication.status == "published"

          publication.update!(
            status: "planned",
            error_code: nil,
            error_message: nil,
            published_at: nil
          )
        end

        undo_history = Array(registration.metadata["undo_history"])
        undo_history << {
          "at" => Time.current.iso8601,
          "by_user_id" => user&.id,
          "product_id" => product&.id,
          "sku" => registration.sku,
          "local_product_was_created_by_registration" => created_local_product
        }

        registration.update!(
          product: nil,
          status: "ready",
          validation_errors: [],
          metadata: registration.metadata.merge(
            "last_undone_at" => Time.current.iso8601,
            "undo_history" => undo_history
          )
        )

        product&.destroy! if created_local_product
      end

      registration.reload
    end

    def validation_messages(registration)
      ensure_same_tenant!(registration)
      messages = []

      messages << "Informe o SKU da nova variação." if registration.sku.blank?
      messages << "Informe o nome da nova variação." if registration.name.blank?
      if registration.price_cents.blank? || registration.price_cents <= 0
        messages << "Informe um preço de venda maior que zero."
      end

      # SKU já existente no Pricecom NÃO é erro: esse é exatamente o caso
      # esperado quando a variação já veio de outro canal (TikTok, Shopify...).
      # A publicação reutiliza o Product existente e adiciona o listing Yampi.

      publications = registration.publications.includes(:channel_credential).to_a
      messages << "Selecione ao menos uma loja/canal de destino." if publications.empty?

      publications.each do |publication|
        next if parent_available_in_destination?(registration.parent_product, publication)

        messages << "A variação-base não está cadastrada em #{destination_label(publication)}."
      end

      if publications.any? { |publication| publication.channel == "yampi" } && !registration_image_ready?(registration)
        messages << "Não foi encontrada uma imagem própria do SKU #{registration.sku} no IDWorks. A publicação Yampi foi bloqueada para evitar usar a imagem errada do produto-base."
      end

      messages.uniq
    end

    private

    attr_reader :tenant, :user

    def ensure_local_product!(registration)
      ProductRegistration.transaction do
        registration.lock!
        return registration.product if registration.product_id.present?

        registration.update!(status: "publishing", validation_errors: [])
        parent = registration.parent_product
        existing = existing_product_for_sku(registration.sku)

        if existing
          registration.update!(
            product: existing,
            status: "waiting_channels",
            validation_errors: [],
            metadata: registration.metadata.merge(
              "parent_product_id" => parent.id,
              "reused_existing_product" => true,
              "existing_product_id" => existing.id,
              "local_product_created_by_registration" => false,
              "channel_credential_ids" => registration.publications.pluck(:channel_credential_id).compact
            )
          )
          return existing
        end

        product = tenant.products.create!(
          sku: registration.sku,
          name: registration.name,
          cost_price: parent.cost_price,
          active: true,
          is_kit: false,
          is_gift: false,
          interest_cost_percent: parent.interest_cost_percent,
          tax_percent: parent.tax_percent,
          platform_fee_percent: parent.platform_fee_percent,
          lead_time_days: parent.lead_time_days,
          lead_time_ignore: parent.lead_time_ignore,
          lead_outlier: false
        )

        registration.update!(
          product: product,
          status: "waiting_channels",
          validation_errors: [],
          metadata: registration.metadata.merge(
            "parent_product_id" => parent.id,
            "local_product_created_at" => Time.current.iso8601,
            "local_product_created_by_registration" => true,
            "reused_existing_product" => false,
            "channel_credential_ids" => registration.publications.pluck(:channel_credential_id).compact
          )
        )

        product
      end
    end

    def existing_product_for_sku(sku)
      normalized = sku.to_s.strip.downcase
      return nil if normalized.blank?

      tenant.products.where("LOWER(sku) = ?", normalized).first
    end

    def sync_idworks_images!(registration, force: false)
      return unless registration.publications.any? { |publication| publication.channel == "yampi" }
      return if registration.images.attached?
      return if !force && Array(registration.metadata["source_image_urls"]).present?

      if force
        registration.update!(
          metadata: registration.metadata.except(
            "source_image_provider",
            "source_image_urls",
            "source_image_details",
            "source_image_idworks_id",
            "source_image_integration_id",
            "source_image_integration_name",
            "source_image_resolved_at",
            "source_image_errors"
          )
        )
      end

      existing_product = existing_product_for_sku(registration.sku)
      result = IdworksSkuImageResolverService.new(
        tenant: tenant,
        sku: registration.sku,
        parent_product: registration.parent_product,
        existing_product: existing_product
      ).call

      metadata = registration.metadata.merge(
        "source_image_provider" => "idworks",
        "source_image_resolved_at" => Time.current.iso8601,
        "source_image_errors" => result.errors
      )

      if result.found?
        metadata.merge!(
          "source_image_urls" => result.image_urls,
          "source_image_details" => result.images,
          "source_image_idworks_id" => result.idworks_id,
          "source_image_integration_id" => result.integration_id,
          "source_image_integration_name" => result.integration_name
        )
      else
        metadata["source_image_urls"] = []
      end

      registration.update!(metadata: metadata)
    rescue => e
      registration.update!(
        metadata: registration.metadata.merge(
          "source_image_provider" => "idworks",
          "source_image_urls" => [],
          "source_image_resolved_at" => Time.current.iso8601,
          "source_image_errors" => [
            { "error_class" => e.class.name, "message" => e.message.to_s.first(300) }
          ]
        )
      )
    end

    def registration_image_ready?(registration)
      registration.images.attached? || Array(registration.metadata["source_image_urls"]).any?
    end

    def local_product_created_by_registration?(registration)
      value = registration.metadata["local_product_created_by_registration"]
      return value == true unless value.nil?
      return false if registration.metadata["reused_existing_product"] == true

      # Compatibilidade com cadastros publicados antes desta flag existir.
      registration.metadata["local_product_created_at"].present?
    end

    def process_publications!(registration)
      registration.publications.includes(:channel_credential).find_each do |publication|
        next if publication.status == "published" && publication.external_variant_id.present?

        case publication.channel
        when "yampi"
          publish_yampi!(registration, publication)
        else
          publication.update!(
            status: "waiting_connector",
            error_code: "publisher_not_configured",
            error_message: "Publicação automática para #{destination_label(publication)} ainda não está habilitada no Pricecom."
          )
        end
      end
    end

    def publish_yampi!(registration, publication)
      YampiProductPublicationService.new(
        registration: registration,
        publication: publication
      ).publish!
    rescue YampiProductPublicationService::PublicationError => e
      publication.update!(
        status: "failed",
        error_code: e.code,
        error_message: e.message,
        last_attempt_at: publication.last_attempt_at || Time.current
      )
    end

    def refresh_publication_state!(registration)
      statuses = registration.publications.reload.pluck(:status)
      status = if statuses.present? && statuses.all? { |value| value == "published" }
        "published"
      elsif statuses.include?("failed") && statuses.include?("published")
        "partial_failure"
      elsif statuses.present? && statuses.all? { |value| value == "failed" }
        "failed"
      else
        "waiting_channels"
      end

      registration.update!(status: status)
    end

    def sync_publications!(registration, channels:, channel_credential_ids:)
      destinations = []

      Array(channel_credential_ids).reject(&:blank?).uniq.each do |credential_id|
        credential = tenant.channel_credentials.find(credential_id)
        unless ProductRegistrationPublication::CHANNELS.include?(credential.channel)
          raise ValidationError, [ "Canal inválido para publicação: #{credential.channel}" ]
        end

        destinations << { channel: credential.channel, channel_credential: credential }
      end

      Array(channels).map { |channel| channel.to_s.downcase.strip }.reject(&:blank?).uniq.each do |channel|
        unless ProductRegistrationPublication::CHANNELS.include?(channel)
          raise ValidationError, [ "Canal inválido: #{channel}" ]
        end

        credentials = tenant.channel_credentials.where(channel: channel).order(:id).limit(2).to_a
        if credentials.many?
          raise ValidationError, [
            "Existem várias lojas em #{channel_label(channel)}. Informe channel_credential_ids para escolher a conexão correta."
          ]
        end

        destinations << { channel: channel, channel_credential: credentials.first }
      end

      destinations.uniq! { |destination| [ destination[:channel], destination[:channel_credential]&.id ] }
      desired_keys = destinations.map { |destination| [ destination[:channel], destination[:channel_credential]&.id ] }

      registration.publications.to_a.each do |publication|
        key = [ publication.channel, publication.channel_credential_id ]
        next if desired_keys.include?(key) || publication.status == "published"

        publication.destroy!
      end

      destinations.each do |destination|
        publication = if destination[:channel_credential]
          registration.publications.find_or_initialize_by(channel_credential: destination[:channel_credential])
        else
          registration.publications.find_or_initialize_by(
            channel: destination[:channel],
            channel_credential_id: nil
          )
        end

        publication.channel = destination[:channel]
        if registration.product_id.blank? && publication.status != "published"
          publication.status = "planned"
          publication.error_code = nil
          publication.error_message = nil
        end
        publication.save!
      end
    end

    def parent_available_in_destination?(parent, publication)
      if publication.channel_credential_id.present?
        return true if parent.channel_product_listings.where(
          channel_credential_id: publication.channel_credential_id
        ).exists?

        single_connection = tenant.channel_credentials.where(channel: publication.channel).limit(2).count == 1
        return single_connection && parent.channel_product_listings.where(
          channel: publication.channel,
          channel_credential_id: nil
        ).exists?
      end

      parent.channel_product_listings.where(channel: publication.channel).exists?
    end

    def refresh_validation_state!(registration)
      errors = validation_messages(registration)
      registration.update!(
        validation_errors: errors,
        status: errors.empty? ? "ready" : "draft"
      )
    end

    def ensure_same_tenant!(registration)
      return if registration.tenant_id == tenant.id

      raise ActiveRecord::RecordNotFound
    end

    def parse_price_cents(value)
      return nil if value.blank?

      parsed = value.is_a?(Integer) ? value : Integer(value.to_s, 10)
      raise ValidationError, [ "Preço inválido." ] if parsed.negative?

      parsed
    rescue ArgumentError, TypeError
      raise ValidationError, [ "Preço inválido." ]
    end

    def channel_label(channel)
      CHANNEL_LABELS.fetch(channel.to_s, channel.to_s.humanize)
    end

    def destination_label(publication)
      credential = publication.channel_credential
      return channel_label(publication.channel) unless credential

      "#{channel_label(publication.channel)} — #{credential.display_name}"
    end
  end
end
