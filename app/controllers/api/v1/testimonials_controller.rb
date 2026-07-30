module Api
  module V1
    # Curadoria de depoimentos de clientes — ver Testimonial::TRANSITIONS pro
    # fluxo de status draft -> approved -> published, ou -> rejected.
    # Ingestão manual (Fase 2) e via link do TikTok (Fase 3, ver
    # #create_from_tiktok/Testimonials::TiktokOembedFetcher). Importação
    # Shopee (Fase 4) ainda não existe.
    class TestimonialsController < ApplicationController
      PER_PAGE_DEFAULT = 25
      PER_PAGE_MAX     = 100

      before_action :require_admin!, only: [
        :create, :update, :destroy, :approve, :publish, :reject, :bulk_import, :bulk_import_status
      ]

      def index
        testimonials = apply_filters(current_tenant.testimonials.includes(:products)).order(created_at: :desc)

        per   = [ [ params.fetch(:per_page, PER_PAGE_DEFAULT).to_i, 1 ].max, PER_PAGE_MAX ].min
        paged = testimonials.page(params[:page]).per(per)

        render json: {
          testimonials: paged.map { |t| testimonial_json(t) },
          meta: pagination_meta(paged)
        }
      end

      # Ingestão manual ou via link do TikTok — o único source_type que o
      # cliente escolhe aqui é "tiktok" (params[:source_type] == "tiktok");
      # qualquer outro valor (ou ausência) sempre cai no caminho manual.
      # status nunca vem do cliente — todo depoimento criado por aqui nasce
      # "draft" e anda pelo fluxo de curadoria a partir das actions
      # approve/publish/reject abaixo.
      def create
        if params[:source_type] == "tiktok"
          create_from_tiktok
        else
          create_manual
        end
      end

      # POST /api/v1/testimonials/tiktok_preview — mesma regra de acesso do
      # index (não é escrita: só consulta o oEmbed público e devolve o
      # metadata pro frontend mostrar antes do usuário confirmar a
      # criação). Não gera nenhum Testimonial.
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

        # product_ids= num registro já persistido grava/apaga na tabela de
        # junção na hora (não espera testimonial.save) — por isso vai numa
        # transaction junto com o update dos demais campos, e qualquer
        # RecordInvalid (ex: produto de outro tenant, ver
        # TestimonialProduct#product_belongs_to_same_tenant) é convertido no
        # mesmo formato de erro 422 do resto do controller, em vez de
        # estourar como 500.
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

      # POST /api/v1/testimonials/:id/approve — só válido a partir de draft
      # (ver Testimonial::TRANSITIONS).
      def approve
        transition(:approved) { |testimonial| testimonial.approve! }
      end

      # POST /api/v1/testimonials/:id/publish — só válido a partir de
      # approved (curadoria precisa aprovar antes de publicar).
      def publish
        transition(:published) { |testimonial| testimonial.publish! }
      end

      # POST /api/v1/testimonials/:id/reject — válido a partir de draft ou
      # approved; um depoimento já publicado não pode ser rejeitado por
      # aqui (precisa de uma decisão explícita de despublicar, fora do
      # escopo desta fase).
      def reject
        transition(:rejected) { |testimonial| testimonial.reject! }
      end

      # POST /api/v1/testimonials/bulk_import — cadastro em massa a partir
      # de um ZIP (CSV + imagens, ver Testimonials::BulkImportService).
      # Responde de imediato com o id do import; o processamento roda em
      # background (pode ser centenas de linhas/imagens) — o cliente
      # consulta o progresso/relatório em #bulk_import_status. Todo
      # testimonial criado por aqui nasce "draft", igual à ingestão manual
      # — nunca published automaticamente, nem em lote.
      def bulk_import
        unless params[:file]
          return render json: { error: "Arquivo não enviado" }, status: :unprocessable_entity
        end

        file = params[:file]
        bulk_import = current_tenant.testimonial_bulk_imports.create!(
          filename: file.original_filename, status: "pending"
        )
        # zip_file, não um path em tmp/ — quem processa (Sidekiq) roda num
        # container separado deste, sem acesso ao filesystem local que
        # recebeu o upload. Ver TestimonialBulkImport#zip_file.
        bulk_import.zip_file.attach(io: file, filename: file.original_filename)

        Testimonials::ProcessBulkImportJob.perform_later(bulk_import.id)

        render json: bulk_import_json(bulk_import), status: :created
      end

      # GET /api/v1/testimonials/bulk_import/:id — polling de progresso;
      # errors traz o relatório linha a linha assim que status vira "done"
      # (ou o motivo em errors[0][:error] se o ZIP/CSV inteiro não pôde
      # nem começar a ser processado e status vira "failed").
      def bulk_import_status
        bulk_import = current_tenant.testimonial_bulk_imports.find(params[:id])
        render json: bulk_import_json(bulk_import)
      end

      private

      # Checa a transição antes de chamar o bang method do model — mesmo
      # padrão do StockAlertsController#confirm/#dismiss: erro claro em vez
      # de deixar o ActiveRecord::RecordInvalid do model estourar.
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
        # Só empilha em memória — has_many :through aceita atribuição num
        # registro ainda não salvo (fica no target, sem tocar o banco) e é
        # persistido no mesmo INSERT/transaction do #save logo abaixo, sem
        # precisar de um segundo save.
        testimonial.product_ids = requested_product_ids if product_ids_requested?

        if testimonial.save
          # Só gera algo se houver mídia (a action no model já protege isso,
          # mas evita nem enfileirar quando não tem o que processar). Os dois
          # jobs re-checam por conta própria (quote_text já preenchido,
          # #media ser imagem) antes de fazer qualquer trabalho pesado.
          if testimonial.media.attached?
            Testimonials::GenerateQuoteTextJob.perform_later(testimonial.id)
            Testimonials::GenerateThumbnailJob.perform_later(testimonial.id)
          end
          render json: testimonial_json(testimonial), status: :created
        else
          render json: { errors: testimonial.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # Busca o oEmbed de novo no momento da criação (em vez de confiar só
      # no preview que o frontend já mostrou) — o preview é só uma consulta
      # de conveniência pro usuário conferir antes de confirmar, não uma
      # fonte de verdade que o backend deveria aceitar sem revalidar.
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
        scope
      end

      def testimonial_params
        params.permit(:customer_name, :rating, :quote_text, :media)
      end

      # true só quando o cliente mandou ALGUM dos dois params nesta request
      # — precisa distinguir "não mandou" (não mexe nos produtos já
      # vinculados, ex: PUT só de quote_text) de "mandou vazio" (limpa todos
      # os produtos vinculados).
      def product_ids_requested?
        params.key?(:product_ids) || params.key?(:product_id)
      end

      # Aceita tanto o formato novo (product_ids, array) quanto o antigo
      # (product_id, singular — formulário/cliente que ainda não migrou),
      # sem quebrar nenhum dos dois.
      def requested_product_ids
        ids = params[:product_ids].presence || params[:product_id]
        Array(ids).reject(&:blank?)
      end

      def testimonial_json(testimonial)
        {
          id: testimonial.id,
          customer_name: testimonial.customer_name,
          products: testimonial.products.map { |product| { id: product.id, name: product.name, sku: product.sku } },
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
        return nil unless testimonial.media.attached?

        Rails.application.routes.url_helpers.rails_blob_path(testimonial.media, only_path: true)
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
