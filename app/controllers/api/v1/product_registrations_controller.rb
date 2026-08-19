module Api
  module V1
    class ProductRegistrationsController < ApplicationController
      before_action :require_admin!
      before_action :set_registration, only: [ :show, :update, :publish, :add_images, :remove_image ]

      rescue_from Products::ProductRegistrationService::ValidationError do |error|
        render json: { errors: error.errors }, status: :unprocessable_entity
      end

      rescue_from ActiveRecord::RecordInvalid do |error|
        render json: { errors: error.record.errors.full_messages }, status: :unprocessable_entity
      end

      def index
        registrations = registration_scope.order(updated_at: :desc)
        registrations = registrations.where(status: params[:status]) if params[:status].present?

        render json: {
          registrations: registrations.limit(100).map { |registration| registration_json(registration) }
        }
      end

      def show
        render json: registration_json(@registration)
      end

      def create
        registration = registration_service.create_draft!(registration_params)
        render json: registration_json(registration), status: :created
      end

      def update
        registration = registration_service.update_draft!(@registration, registration_params)
        render json: registration_json(registration)
      end

      def publish
        registration = registration_service.publish!(@registration)
        render json: registration_json(registration)
      end

      def add_images
        files = Array(params[:images]).compact
        if files.empty?
          return render json: { errors: [ "Selecione ao menos uma imagem." ] }, status: :unprocessable_entity
        end

        invalid_files = files.reject do |file|
          file.respond_to?(:content_type) && file.content_type.to_s.start_with?("image/")
        end
        if invalid_files.any?
          return render json: { errors: [ "Todos os arquivos enviados precisam ser imagens." ] }, status: :unprocessable_entity
        end

        @registration.images.attach(files)
        render json: registration_json(@registration.reload)
      end

      def remove_image
        attachment = @registration.images.attachments.find(params[:attachment_id])
        attachment.purge
        render json: registration_json(@registration.reload)
      end

      private

      def registration_scope
        ProductRegistration
          .where(tenant: current_tenant)
          .includes(:parent_product, :product, :publications, images_attachments: :blob)
      end

      def set_registration
        @registration = registration_scope.find(params[:id])
      end

      def registration_service
        @registration_service ||= Products::ProductRegistrationService.new(
          tenant: current_tenant,
          user: current_user
        )
      end

      def registration_params
        params.permit(:parent_product_id, :sku, :name, :price_cents, channels: [])
      end

      def registration_json(registration)
        {
          id: registration.id,
          status: registration.status,
          sku: registration.sku,
          name: registration.name,
          price_cents: registration.price_cents,
          validation_errors: registration.validation_errors,
          parent_product: product_reference_json(registration.parent_product, include_channels: true),
          product: product_reference_json(registration.product),
          publications: registration.publications.sort_by(&:channel).map { |publication| publication_json(publication) },
          images: registration.images.map { |image| image_json(image) },
          created_at: registration.created_at,
          updated_at: registration.updated_at
        }
      end

      def product_reference_json(product, include_channels: false)
        return nil unless product

        result = { id: product.id, sku: product.sku, name: product.name }
        result[:channels] = product.channel_names.sort if include_channels
        result
      end

      def publication_json(publication)
        {
          id: publication.id,
          channel: publication.channel,
          status: publication.status,
          external_product_id: publication.external_product_id,
          external_variant_id: publication.external_variant_id,
          error_code: publication.error_code,
          error_message: publication.error_message,
          attempts: publication.attempts,
          last_attempt_at: publication.last_attempt_at,
          published_at: publication.published_at
        }
      end

      def image_json(image)
        {
          id: image.id,
          filename: image.filename.to_s,
          content_type: image.blob.content_type,
          byte_size: image.blob.byte_size,
          url: Rails.application.routes.url_helpers.rails_blob_path(image, only_path: true)
        }
      end
    end
  end
end
