class AddIntegrationToProducts < ActiveRecord::Migration[7.2]
  def change
    # Loja (Hidrabene x Anasol) não é um campo próprio — é derivada de qual
    # Integration idworks (provider: "idworks", uma por empresa/loja)
    # sincronizou o catálogo desse produto por último. Ver
    # Integrations::Idworks::ProductCostSyncService#apply_to_product e
    # Idworks::DashboardStatsService.
    add_reference :products, :integration, foreign_key: true, index: true
  end
end
