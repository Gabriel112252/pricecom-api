class ProcessImportJob < ApplicationJob
  queue_as :default

  def perform(import_id)
    import = Import.find(import_id)
    file_path = Rails.root.join("tmp", "imports", import.filename)
    Orders::ImportService.new(import.tenant, file_path.to_s, import).call
  end
end
