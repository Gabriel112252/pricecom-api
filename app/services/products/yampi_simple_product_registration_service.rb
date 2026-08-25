# frozen_string_literal: true

module Products
  # Orquestra o modo "produto normal" sem passar pelo publisher de variações.
  # O Product do Pricecom continua sendo identidade global por SKU: se 2142_2
  # já veio do TikTok, ele é reutilizado e recebe apenas o listing da Yampi.
  class YampiSimpleProductRegistrationService
    def initialize(tenant:, user: nil)
      @tenant = tenant
      @user = user
    end

    def publish!(registration)
      ensure_same_tenant!(registration)
      registration.reload
      yampi_publications = registration.publications.includes(:channel_credential).select { |p| p.channel == "yampi" }
      if yampi_publications.empty?
        raise ProductRegistrationService::ValidationError, [ "O cadastro não possui destino Yampi." ]
      end

      non_yampi = registration.publications.reject { |p| p.channel == "yampi" }
      if non_yampi.any?
        raise ProductRegistrationService::ValidationError, [
          "O modo produto_simples é exclusivo para Yampi. Publique outros canais em um cadastro separado."
        ]
      end

      errors = ProductRegistrationService.new(tenant: tenant, user: user).validation_messages(registration)
      if errors.any?
        registration.update!(status: "draft", validation_errors: errors)
        raise ProductRegistrationService::ValidationError, errors
      end

      ensure_local_product!(registration) if registration.product_id.blank?
      registration.update!(
        status: "publishing",
        validation_errors: [],
        metadata: registration.metadata.merge(
          "yampi_publication_mode" => YampiSimpleProductPublicationService::PUBLICATION_MODE,
          "yampi_publication_mode_selected_at" => Time.current.iso8601
        )
      )

      yampi_publications.each do |publication|
        YampiSimpleProductPublicationService.new(
          registration: registration.reload,
          publication: publication.reload
        ).publish!
      rescue YampiProductPublicationService::PublicationError => e
        publication.update!(
          status: "failed",
          error_code: e.code,
          error_message: e.message,
          last_attempt_at: publication.last_attempt_at || Time.current,
          metadata: publication.metadata.merge("publication_mode" => YampiSimpleProductPublicationService::PUBLICATION_MODE)
        )
      end

      refresh_state!(registration)
      registration.reload
    rescue ActiveRecord::RecordInvalid => e
      raise ProductRegistrationService::ValidationError, e.record.errors.full_messages
    end

    private

    attr_reader :tenant, :user

    def ensure_same_tenant!(registration)
      raise ActiveRecord::RecordNotFound unless registration.tenant_id == tenant.id
    end

    def ensure_local_product!(registration)
      ProductRegistration.transaction do
        registration.lock!
        return registration.product if registration.product_id.present?

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

    def refresh_state!(registration)
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
  end
end
