module Api
  module V1
    # Curadoria de depoimentos de clientes — ver Testimonial::TRANSITIONS pro
    # fluxo de status draft -> approved -> published, ou -> rejected.
    # Ingestão manual, TikTok e import em massa (incluindo Mercado Livre).
    class TestimonialsController < ApplicationController
      PER_PAGE_DEFAULT = 25
      PER_PAGE_MAX     = 100

      before_action :require_admin!, only: [
        :create, :update, :destroy, :approve, :publish, :reject, :bulk_import, :bulk_import_status
      ]

      def index
        testimonials = apply_filters(
          current_tenant.testimonials.includes(:products)
        ).order(created_at: :desc)

        per   = [ [ params.fetch(:per_page, PER_PAGE_DEFAULT).to_i, 1 ].max, PER_PAGE_MAX ].min
        paged = testimonials.page(params[:page]).per(per)

        render json: {
          testimonials: paged.map { |t| testimonial_json(t) },
          meta: pagination_meta(paged)
        }
      end

      def create
        if params[:source_type] == "tiktok"
          create_from_tiktok
        else
          create_manual
        end
      end

      def tiktok_preview
        result = Testimonials::TiktokOembedFetcher.call(params[:url].to_s)

        if result[:success]
          render json: result[:data]
        else
          render json: { error: result[:error] }, status: :unprocessable_entity
        end
      end

      def update
        testimonial = current_tenant.testimonials.find(params[:id])

        Testimonial.transaction do
          testimonial.product_ids = requested_product_ids if product_ids_requested?
          testimonial.update!(testimonial_params)
        end
        render json: testimonial_json(testimonial)
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      end

      def destroy
        testimonial = current_tenant.testimonials.find(params[:id])
        testimonial.destroy!
        head :no_content
      end

      def approve
        transition(:approved) { |testimonial| testimonial.approve! }
      end

      def publish
        transition(:published) { |testimonial| testimonial.publish! }
      end

      def reject
        transition(:rejected) { |testimonial| testimonial.reject! }
      end

      # POST /api/v1/testimonials/bulk_import — ZIP com CSV + imagens.
      # image_filename pode estar vazio por linha; source_type/external_url
      # são opcionais e permitem preservar a origem pública da avaliação.
      # image_url também é opcional e aponta para uma foto pública externa.
      # Todo testimonial nasce draft e exige curadoria antes de publicar.
      def bulk_import
        unless params[:file]
          return render json: { error: "Arquivo não enviado" }, status: :unprocessable_entity
        end

        file = params[:file]
        bulk_import = current_tenant.testimonial_bulk_imports.create!(
          filename: file.original_filename, status: "pending"
        )
        bulk_import.zip_file.attach(io: file, filename: file.original_filename)

        Testimonials::ProcessBulkImportJob.perform_later(bulk_import.id)

        render json: bulk_import_json(bulk_import), status: :created
      end

      def bulk_import_status
        bulk_import = current_tenant.testimonial_bulk_imports.find(params[:id])
        render json: bulk_import_json(bulk_import)
      end

      private

      def transition(target_status)
        testimonial = current_tenant.testimonials.find(params[:id])

        allowed = Testimonial::TRANSITIONS.fetch(testimonial.status, [])
        unless allowed.include?(target_status.to_s)
          return render json: {
            error: "não é possível mudar de '#{testimonial.status}' para '#{target_status}'"
          }, status: :unprocessable_entity
        end

        yield testimonial
        render json: testimonial_json(testimonial)
      end

      def create_manual
        testimonial = current_tenant.testimonials.new(
          testimonial_params.merge(source_type: "manual", status: "draft")
        )
        testimonial.product_ids = requested_product_ids if product_ids_requested?

        if testimonial.save
          if testimonial.media.attached?
            Testimonials::GenerateQuoteTextJob.perform_later(testimonial.id)
            Testimonials::GenerateThumbnailJob.perform_later(testimonial.id)
          end
          render json: testimonial_json(testimonial), status: :created
        else
          render json: { errors: testimonial.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def create_from_tiktok
        url = params[:external_url].to_s
        result = Testimonials::TiktokOembedFetcher.call(url)

        unless result[:success]
          return render json: { errors: [ result[:error] ] }, status: :unprocessable_entity
        end

        testimonial = current_tenant.testimonials.new(
          testimonial_params.merge(
            source_type: "tiktok",
            status: "draft",
            external_url: url,
            tiktok_metadata: result[:data]
          )
        )
        testimonial.product_ids = requested_product_ids if product_ids_requested?

        if testimonial.save
          Testimonials::DownloadTiktokVideoJob.perform_later(testimonial.id)
          render json: testimonial_json(testimonial), status: :created
        else
          render json: { errors: testimonial.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def apply_filters(scope)
        scope = scope.by_status(params[:status]) if params[:status].present?
        scope = scope.by_source_type(params[:source_type]) if params[:source_type].present?

        # Hidrabene e Anasol compartilham a mesma integração IDWorks. A loja
        # é derivada do produto, usando a regra centralizada em Product.
        if params[:loja].present?
          return scope.none unless Product::STORE_KEYS.include?(params[:loja])

          scope = scope
            .joins(:products)
            .where(products: { id: current_tenant.products.for_store(params[:loja]).select(:id) })
            .distinct
        end

        scope
      end

      def testimonial_params
        params.permit(:customer_name, :rating, :quote_text, :media)
      end

      def product_ids_requested?
        params.key?(:product_ids) || params.key?(:product_id)
      end

      def requested_product_ids
        ids = params[:product_ids].presence || params[:product_id]
        Array(ids).reject(&:blank?)
      end

      def testimonial_json(testimonial)
        {
          id: testimonial.id,
          customer_name: testimonial.customer_name,
          products: testimonial.products.map do |product|
            {
              id: product.id,
              name: product.name,
              sku: product.sku,
              store_key: product.store_key
            }
          end,
          rating: testimonial.rating,
          quote_text: testimonial.quote_text,
          status: testimonial.status,
          source_type: testimonial.source_type,
          media_url: media_url(testimonial),
          external_url: testimonial.external_url,
          tiktok_metadata: testimonial.tiktok_metadata,
          approved_at: testimonial.approved_at,
          published_at: testimonial.published_at,
          created_at: testimonial.created_at
        }
      end

      def media_url(testimonial)
        if testimonial.media.attached?
          return Rails.application.routes.url_helpers.rails_blob_path(testimonial.media, only_path: true)
        end

        external_image_url(testimonial)
      end

      def external_image_url(testimonial)
        metadata = testimonial.tiktok_metadata
        return nil unless metadata.is_a?(Hash)

        metadata["external_image_url"].presence
      end

      def bulk_import_json(bulk_import)
        {
          id: bulk_import.id,
          status: bulk_import.status,
          total_rows: bulk_import.total_rows,
          processed_rows: bulk_import.processed_rows,
          error_rows: bulk_import.error_rows,
          errors: bulk_import.errors_log,
          finished_at: bulk_import.finished_at
        }
      end

      def pagination_meta(paged)
        {
          current_page: paged.current_page,
          total_pages:  paged.total_pages,
          total_count:  paged.total_count,
          per_page:     paged.limit_value
        }
      end
    end
  end
end
