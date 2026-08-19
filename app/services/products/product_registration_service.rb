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
        sync_publications!(registration, attrs[:channels])
        refresh_validation_state!(registration)
      end

      registration.reload
    end

    def update_draft!(registration, attributes)
      ensure_same_tenant!(registration)
      if registration.product_id.present?
        raise ValidationError, [ "O produto já foi criado no Pricecom e o rascunho não pode mais alterar seus dados-base." ]
      end

      attrs = attributes.to_h.with_indifferent_access

      ProductRegistration.transaction do
        if attrs[:parent_product_id].present?
          registration.parent_product = tenant.products.find(attrs[:parent_product_id])
        end
        registration.sku = attrs[:sku].to_s.strip if attrs.key?(:sku)
        registration.name = attrs[:name].to_s.strip if attrs.key?(:name)
        registration.price_cents = parse_price_cents(attrs[:price_cents]) if attrs.key?(:price_cents)
        registration.save!

        sync_publications!(registration, attrs[:channels]) if attrs.key?(:channels)
        refresh_validation_state!(registration)
      end

      registration.reload
    end

    def publish!(registration)
      ensure_same_tenant!(registration)
      registration.reload
      return registration if registration.product_id.present?

      errors = validation_messages(registration)
      if errors.any?
        registration.update!(status: "draft", validation_errors: errors)
        raise ValidationError, errors
      end

      ProductRegistration.transaction do
        registration.lock!
        return registration if registration.product_id.present?

        registration.update!(status: "publishing", validation_errors: [])
        parent = registration.parent_product

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

        registration.publications.find_each do |publication|
          publication.update!(
            status: "waiting_connector",
            error_code: "publisher_not_configured",
            error_message: "Publicação automática para #{channel_label(publication.channel)} ainda não está habilitada no Pricecom."
          )
        end

        registration.update!(
          product: product,
          status: "waiting_channels",
          validation_errors: [],
          metadata: registration.metadata.merge(
            "parent_product_id" => parent.id,
            "local_product_created_at" => Time.current.iso8601
          )
        )
      end

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
      errors = [ "Já existe um produto com este SKU." ]
      registration.update_columns(
        status: "failed",
        validation_errors: errors,
        updated_at: Time.current
      ) if registration.persisted?
      raise ValidationError, errors
    end

    def validation_messages(registration)
      ensure_same_tenant!(registration)
      messages = []

      messages << "Informe o SKU da nova variação." if registration.sku.blank?
      messages << "Informe o nome da nova variação." if registration.name.blank?
      if registration.price_cents.blank? || registration.price_cents <= 0
        messages << "Informe um preço de venda maior que zero."
      end

      duplicate_scope = tenant.products.where("LOWER(sku) = ?", registration.sku.to_s.downcase)
      duplicate_scope = duplicate_scope.where.not(id: registration.product_id) if registration.product_id.present?
      messages << "Já existe um produto com este SKU no Pricecom." if registration.sku.present? && duplicate_scope.exists?

      selected_channels = registration.publications.pluck(:channel)
      messages << "Selecione ao menos um canal de destino." if selected_channels.empty?

      parent_channels = registration.parent_product.channel_product_listings.distinct.pluck(:channel)
      unavailable = selected_channels - parent_channels
      unavailable.each do |channel|
        messages << "A variação-base não está cadastrada em #{channel_label(channel)}."
      end

      messages.uniq
    end

    private

    attr_reader :tenant, :user

    def sync_publications!(registration, channels)
      selected = Array(channels).map { |channel| channel.to_s.downcase.strip }.reject(&:blank?).uniq
      invalid = selected - ProductRegistrationPublication::CHANNELS
      raise ValidationError, invalid.map { |channel| "Canal inválido: #{channel}" } if invalid.any?

      registration.publications.to_a.each do |publication|
        next if selected.include?(publication.channel) || publication.status == "published"

        publication.destroy!
      end

      selected.each do |channel|
        publication = registration.publications.find_or_initialize_by(channel: channel)
        if registration.product_id.blank? && publication.status != "published"
          publication.status = "planned"
          publication.error_code = nil
          publication.error_message = nil
        end
        publication.save!
      end
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
  end
end
