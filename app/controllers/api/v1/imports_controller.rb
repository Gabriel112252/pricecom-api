module Api
  module V1
    class ImportsController < ApplicationController
      def index
        imports = current_tenant.imports.order(created_at: :desc).limit(20)
        render json: imports
      end

      def create
        unless params[:file]
          return render json: { error: "Arquivo não enviado" }, status: :unprocessable_entity
        end

        file = params[:file]
        filename = "#{SecureRandom.hex(8)}_#{file.original_filename}"
        dir = Rails.root.join("tmp", "imports")
        FileUtils.mkdir_p(dir)
        File.binwrite(dir.join(filename), file.read)

        import = current_tenant.imports.create!(
          filename: filename,
          status: "pending"
        )

        ProcessImportJob.perform_later(import.id)

        render json: { id: import.id, status: "pending" }, status: :created
      end

      def show
        import = current_tenant.imports.find(params[:id])
        render json: import
      end
    end
  end
end
